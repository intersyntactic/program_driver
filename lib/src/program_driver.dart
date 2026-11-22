import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_executor/is_executor.dart' as executor;
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'installed_programs.dart';
import 'request.dart';

/// The program driver: a service on a Unix socket that starts programs under
/// its root, the suit's home, for the airlock's user alone.
///
/// A caller connects, sends one request as JSON and closes its side. For a
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

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  late final _executor = executor.Executor(
    root: root,
    consent: _decidedByTheAirlock,
    timeout: timeout,
    onStarted: (pid, _) => _running.add(pid),
    onExited: _running.remove,
  );

  /// The process groups of the programs running now, by their leaders' pids.
  final _running = <int>{};

  /// A program to run is its name, its arguments and its stdin, so far
  /// smaller than this.
  static const maxRequest = 1 << 20;

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
    SocketUserReader? socketUserReader,
  }) async {
    final server = await _bind(socket);
    final chmod = await Process.run('chmod', ['0660', socket.path]);
    if (chmod.exitCode != 0) {
      await server.close();
      throw FileSystemException('chmod 0660: ${chmod.stderr}', socket.path);
    }
    final driver = ProgramDriver._(
      root,
      timeout,
      quiet,
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
  /// running, so none outlives the driver.
  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
    for (final leader in _running.toList()) {
      await Process.run('kill', ['-KILL', '--', '-$leader']);
    }
  }

  Future<void> _serve(Socket socket) async {
    try {
      if (!_socketUserCheck.allows(socket)) {
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
    final ProgramDriverRequest request;
    try {
      request = ProgramDriverRequest.fromJson(jsonDecode(utf8.decode(bytes)));
    } on FormatException catch (e) {
      // Infra's deploy proof matches this text on the box, so it changes
      // only together with that proof.
      message(Finished(Refused('not a start: ${e.message}')));
      return;
    }
    switch (request) {
      case RunProgram(:final program, :final args):
        final outcome = await _run(
          program,
          args,
          report: (p) => message(Reported(p)),
        );
        message(Finished(outcome));
      case ListInstalledPrograms():
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
  Future<Outcome<ExecResult>> _run(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final path = _programs.pathOf(program);
    if (path == null) {
      return Refused('no program named $program is installed here');
    }
    final running = _executor.start(
      [path, ...args.args],
      input: args.stdin,
      workingSubdir: args.inFolder.value,
      quiet: quiet,
      taps: executor.ExecTaps.none,
    );
    final (start, _, _) = await (
      running.result,
      running.stdout.forEach((t) => report(Printed(Channel.stdout, t))),
      running.stderr.forEach((t) => report(Printed(Channel.stderr, t))),
    ).wait;
    return _outcome(start);
  }

  Outcome<ExecResult> _outcome(executor.ExecStart start) => switch (start) {
    executor.ExecStarted(:final result) => Ran(switch (result) {
      executor.ExecResult(:final silentFor?) => Killed(
        'printed nothing for ${silentFor.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      executor.ExecResult(timedOut: true) => Killed(
        'timed out after ${timeout.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      _ => Exited(
        result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      ),
    }),
    executor.ExecNotStarted(:final why) => Refused(why),
  };
}
