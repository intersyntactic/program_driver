import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_executor/is_executor.dart' as executor;

/// The program driver: a service on a Unix socket that starts programs under
/// its root, the suit's home, for the airlock's user alone.
///
/// A caller connects, sends one program to run (see [encodeProgramToRun]) as
/// JSON and closes its side; the driver answers one line per
/// [ProgramMessage] (see [encodeProgramMessage], with [encodeExecResult] for
/// the outcome): a [Reported] for each piece the program prints, as it
/// prints it, then one [Finished], and closes. Who is calling is read from
/// the socket as the kernel reports it, never from the request.
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
    this._caller,
    this._socket,
    this._server,
  );

  final Directory root;

  /// How long a program may run before its group is killed.
  final Duration timeout;

  /// When given, how long a program may print nothing once it has started
  /// printing.
  final Duration? quiet;

  final int _caller;
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

  /// Listens on [socket] for the user [caller] alone, starting programs under
  /// [root]. The socket is made readable and writable by its group, the
  /// suit's own, which is how the airlock's user reaches it; a socket file
  /// nothing listens on is replaced.
  static Future<ProgramDriver> start({
    required Directory root,
    required int caller,
    required File socket,
    required Duration timeout,
    Duration? quiet,
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
      caller,
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
    final uid = _peerUid(socket);
    try {
      if (uid != _caller) {
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
      void send(ProgramMessage<ExecResult> message) => socket.add(
        utf8.encode(
          '${jsonEncode(encodeProgramMessage(message, encodeExecResult))}\n',
        ),
      );
      final outcome = tooLarge
          ? const Refused('request too large')
          : await _answer(request.takeBytes(), send);
      send(Finished(outcome));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// Runs the program to run in [bytes], reporting through [send].
  Future<Outcome<ExecResult>> _answer(
    Uint8List bytes,
    void Function(ProgramMessage<ExecResult>) send,
  ) async {
    final ProgramName program;
    final Args args;
    try {
      (program, args) = decodeProgramToRun(jsonDecode(utf8.decode(bytes)));
    } on FormatException catch (e) {
      // Infra's deploy proof matches this text on the box, so it changes
      // only together with that proof.
      return Refused('not a start: ${e.message}');
    }
    return _run(program, args, report: (p) => send(Reported(p)));
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
    final running = _executor.start(
      [program.value, ...args.args],
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

/// The user on the other end of [socket], as the kernel reports it: Linux's
/// `SO_PEERCRED`, macOS's `LOCAL_PEERCRED`. Null where neither is known.
int? _peerUid(Socket socket) {
  try {
    if (Platform.isLinux) {
      final ucred = socket.getRawOption(RawSocketOption(1, 17, Uint8List(12)));
      return ByteData.sublistView(ucred).getUint32(4, Endian.host);
    }
    if (Platform.isMacOS) {
      final xucred = socket.getRawOption(RawSocketOption(0, 1, Uint8List(76)));
      return ByteData.sublistView(xucred).getUint32(4, Endian.host);
    }
  } on SocketException {
    return null;
  }
  return null;
}
