import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_executor/is_executor.dart' as executor;
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'installed_programs.dart';
import 'system_program.dart';

/// The program driver: a service on a Unix socket that starts programs under
/// its root, the suit's home, for the airlock's user alone.
///
/// A caller connects, sends one [ProgramRequest] as JSON (see
/// [encodeProgramRequest]) and closes its side. For a
/// program to run, the driver answers one line per [ProgramMessage] (see
/// [encodeProgramMessage], with [encodeExecResult] for the outcome): a
/// [Reported] for each piece the program prints, as it prints it, then one
/// [Finished]. Asked which programs are installed, it answers one line,
/// their names. Then it closes. Who is calling is read from the socket as
/// the kernel reports it, never from the request.
///
/// It runs as the suit, so a program it starts can do what that suit can and
/// no more: that is the wall. Each program runs in the folder its
/// [Args.inFolder] names under the root, which must resolve inside it, leads
/// a process group of its own, and is killed with everything it started when
/// it runs past [timeout].
///
/// A start reaches it only once the airlock has decided and recorded it, so
/// it asks nobody.
final class ProgramDriver {
  ProgramDriver._(
    this.root,
    this.timeout,
    this.quiet,
    this.maxOutputBytes,
    this._programs,
    this._socketUserCheck,
    this._socket,
    this._server,
  );

  final Directory root;

  /// The programs it runs, found by name in the box's programs folder and
  /// never on the PATH.
  final InstalledPrograms _programs;

  /// How long a program may run before its group is killed.
  final Duration timeout;

  /// When given, how long a program may print nothing once it has started
  /// printing.
  final Duration? quiet;

  /// The most a program may print on stdout, and on stderr, before its group
  /// is killed. Only that much is kept: what it printed past it is never
  /// reported or recorded.
  final int maxOutputBytes;

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  /// The runs not yet finished, each able to kill its program's group.
  final _running = <executor.Running>{};

  /// A program to run is its name, its arguments and its stdin, so far
  /// smaller than this.
  static const maxRequest = 1 << 20;

  static const defaultMaxOutputBytes = 8 << 20;

  /// Listens on [socket] for the user [caller] alone, starting the
  /// [programs] installed, and no others, in folders under [root]. The
  /// socket is made readable and writable by its group, the suit's own,
  /// which is how the airlock's user reaches it; a socket file nothing
  /// listens on is replaced. A connection whose user [socketUserReader]
  /// cannot read is turned away.
  static Future<ProgramDriver> start({
    required Directory root,
    required InstalledPrograms programs,
    required UserId caller,
    required File socket,
    required Duration timeout,
    Duration? quiet,
    int maxOutputBytes = defaultMaxOutputBytes,
    SocketUserReader? socketUserReader,
  }) async {
    final server = await _bind(socket);
    final chmodProgram = SystemProgram.chmod.find();
    if (chmodProgram == null) {
      await server.close();
      throw FileSystemException(SystemProgram.chmod.missing, socket.path);
    }
    final chmod = await Process.run(chmodProgram.path, ['0660', socket.path]);
    if (chmod.exitCode != 0) {
      await server.close();
      throw FileSystemException('chmod 0660: ${chmod.stderr}', socket.path);
    }
    final driver = ProgramDriver._(
      root,
      timeout,
      quiet,
      maxOutputBytes,
      programs,
      SocketUserCheck.only(caller, reader: socketUserReader),
      socket,
      server,
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  /// Stops listening and kills the process group of every program still
  /// running, completing once each is gone, so none outlives the driver.
  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
    await Future.wait([for (final run in _running.toList()) run.kill()]);
  }

  Future<void> _serve(Socket socket) async {
    try {
      final verdict = _socketUserCheck.decide(socket);
      switch (verdict) {
        case Allowed():
          break;
        case NotAllowed() || Unread():
          stderr.writeln('refused a peer: $verdict');
          socket.destroy();
          return;
      }
      final request = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (request.length + chunk.length > maxRequest) {
          tooLarge = true;
          break;
        }
        request.add(chunk);
      }
      void send(Object? json) =>
          socket.add(utf8.encode('${jsonEncode(json)}\n'));
      void message(ProgramMessage<ExecResult> m) =>
          send(encodeProgramMessage(m, encodeExecResult));
      if (tooLarge) {
        message(const Finished(Refused('request too large')));
      } else {
        await _answer(request.takeBytes(), send, message);
      }
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// Answers the request in [bytes]: a run with a line per message through
  /// [message], a list of the installed programs with one line through
  /// [send].
  Future<void> _answer(
    Uint8List bytes,
    void Function(Object? json) send,
    void Function(ProgramMessage<ExecResult>) message,
  ) async {
    final ProgramRequest request;
    try {
      request = decodeProgramRequest(jsonDecode(utf8.decode(bytes)));
    } on FormatException catch (e) {
      // Infra's deploy proof matches this text on the box, so it changes
      // only together with that proof.
      message(Finished(Refused('not a start: ${e.message}')));
      return;
    }
    switch (request) {
      case RunProgramRequest(:final program, :final args):
        final outcome = await _run(
          program,
          args,
          report: (p) => message(Reported(p)),
        );
        message(Finished(outcome));
      case ListInstalledProgramsRequest():
        send(encodeProgramNames(_programs.names));
    }
  }

  /// The executor's consent, already given: a start reaches this driver only
  /// once the airlock's decision is recorded, and asking again would put a
  /// decided run to the person a second time.
  static Future<bool> _decidedByTheAirlock(executor.ExecRequest _) async =>
      true;

  /// Reports what the program prints as it prints it, and returns only once
  /// all of it has been reported, so nothing is reported after the outcome.
  ///
  /// Once it prints more than [maxOutputBytes] on either channel, the
  /// executor kills it with its group, and it ends [Killed], keeping what it
  /// printed up to that many bytes on each, cut where a character ends.
  Future<Outcome<ExecResult>> _run(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final path = _programs.pathOf(program);
    if (path == null) {
      return Refused('no program named $program is installed here');
    }
    final running =
        executor.Executor(
          root: root,
          consent: _decidedByTheAirlock,
          timeout: timeout,
        ).start(
          [path, ...args.args],
          input: args.stdin,
          workingSubdir: args.inFolder.value,
          quiet: quiet,
          maxOutputBytes: maxOutputBytes,
          taps: executor.ExecTaps.none,
        );
    _running.add(running);
    unawaited(running.result.whenComplete(() => _running.remove(running)));
    final (start, _, _) = await (
      running.result,
      running.stdout.forEach((t) => report(Printed(Channel.stdout, t))),
      running.stderr.forEach((t) => report(Printed(Channel.stderr, t))),
    ).wait;
    return _outcome(start);
  }

  Outcome<ExecResult> _outcome(executor.ExecStart start) => switch (start) {
    executor.ExecStarted(:final result) => Ran(switch (result.whyKilled) {
      executor.KilledForSilence(:final quiet) => Killed(
        'printed nothing for ${quiet.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      executor.KilledForTimeout() => Killed(
        'timed out after ${timeout.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      executor.KilledForOutput(:final channel, :final limit) => Killed(
        'printed more than $limit bytes on ${_channel(channel).name}',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      // Only close() asks for a kill.
      executor.KilledOnRequest() => Killed(
        'killed as the program driver stopped',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      null => Exited(
        result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      ),
    }),
    executor.ExecNotStarted(:final why) => Refused(why),
  };

  static Channel _channel(executor.OutputChannel channel) => switch (channel) {
    executor.OutputChannel.stdout => Channel.stdout,
    executor.OutputChannel.stderr => Channel.stderr,
  };
}
