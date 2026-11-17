/// The program driver as a service of its own, which only the airlock's user
/// may call. It runs as the suit a trajectory's agent wears, so a program it
/// starts can do what that suit can and no more.
///
/// A caller connects to the Unix socket, sends one program to run (see
/// [encodeProgramToRun]) and closes its side; the service answers one line
/// per [ProgramMessage] (see [encodeProgramMessage], with [encodeExecResult]
/// for the outcome): a [Reported] for each piece the program
/// prints, as it prints it, then one [Finished], and closes.
/// [SocketProgramDriver] is that caller.
///
/// Who is calling is read from the socket as the kernel reports it, never
/// from the request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';

final class ProgramDriverService {
  ProgramDriverService._(
    this._driver,
    this._caller,
    this._socket,
    this._server,
  );

  final RunsPrograms _driver;
  final int _caller;
  final File _socket;
  final ServerSocket _server;

  /// A program to run is its name, its arguments and its stdin, so far
  /// smaller than this.
  static const maxRequest = 1 << 20;

  /// Listens on [socket], starting programs through [driver] for the user
  /// [caller] alone. The socket is made readable and writable by its group,
  /// the suit's own, which is how the airlock's user reaches it; a
  /// socket file nothing listens on is replaced.
  static Future<ProgramDriverService> start(
    RunsPrograms driver,
    int caller,
    File socket,
  ) async {
    final server = await _bind(socket);
    final chmod = await Process.run('chmod', ['0660', socket.path]);
    if (chmod.exitCode != 0) {
      await server.close();
      throw FileSystemException('chmod 0660: ${chmod.stderr}', socket.path);
    }
    final service = ProgramDriverService._(driver, caller, socket, server);
    service._server.listen(service._serve);
    return service;
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

  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
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
      send(Finished(await _run(tooLarge ? null : request.takeBytes(), send)));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// Runs the program to run in [request] (null: it was too large),
  /// reporting through [send].
  Future<Outcome<ExecResult>> _run(
    Uint8List? request,
    void Function(ProgramMessage<ExecResult>) send,
  ) async {
    if (request == null) return const Refused('request too large');
    final ProgramName program;
    final Args args;
    try {
      (program, args) = decodeProgramToRun(jsonDecode(utf8.decode(request)));
    } on FormatException catch (e) {
      // Infra's deploy proof matches this text on the box, so it changes
      // only together with that proof.
      return Refused('not a start: ${e.message}');
    }
    return _driver.runProgram(
      program,
      args,
      report: (progress) => send(Reported(progress)),
    );
  }
}

/// [RunsPrograms] in another process: sends each program to run to the
/// service at [socket] and reports what comes back as it comes.
final class SocketProgramDriver implements RunsPrograms {
  SocketProgramDriver(this.socket);

  final File socket;

  /// [Refused] only when the service could not be reached, so nothing was
  /// sent. Once the program to run is sent, a run that ends without its
  /// [Finished] throws [OutcomeUnknown]: the program may have started, even
  /// having printed nothing, and may still be running, and no outcome in the
  /// contract says that.
  @override
  Future<Outcome<ExecResult>> runProgram(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final Socket s;
    try {
      s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
    } on SocketException catch (e) {
      return Refused('program driver: ${e.message}');
    }
    try {
      s.add(utf8.encode(jsonEncode(encodeProgramToRun(program, args))));
      await s.close();
      await for (final line
          in s
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        switch (decodeProgramMessage(jsonDecode(line), decodeExecResult)) {
          case Reported(:final progress):
            report(progress);
          case Finished(:final outcome):
            return outcome;
        }
      }
      throw const OutcomeUnknown('the connection closed before it finished');
    } on SocketException catch (e) {
      throw OutcomeUnknown(e.message);
    } on FormatException catch (e) {
      throw OutcomeUnknown('bad answer: ${e.message}');
    }
  }
}

/// A start was sent to the program driver and its outcome never came back,
/// because [why]: the program may not have started, may have finished, or
/// may still be running. Thrown, not recorded as an outcome, since every
/// outcome the contract has would claim to know which.
final class OutcomeUnknown implements Exception {
  const OutcomeUnknown(this.why);

  final String why;

  @override
  String toString() => 'program driver: outcome unknown: $why';
}

/// The user on the other end of [socket], as the kernel reports it: Linux's
/// `SO_PEERCRED`, macOS's `LOCAL_PEERCRED`. Null where neither is known.
/// The same as is_web_driver's service and is_journal's writer read theirs.
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
