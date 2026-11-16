/// The program driver as a service of its own, which only the airlock's user
/// may call. It runs as the journey's OS user, so a program it starts can do
/// what that user can and no more.
///
/// A caller connects to the Unix socket, sends one start (see [encodeStart])
/// and closes its side; the service answers one line per [ProgramMessage]
/// (see [encodeProgramMessage]): a [Reported] for each piece the program
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

  final ProgramDriver _driver;
  final int _caller;
  final File _socket;
  final ServerSocket _server;

  /// A start is a program's name, its arguments and its stdin, so far
  /// smaller than this.
  static const maxRequest = 1 << 20;

  /// Listens on [socket], starting programs through [driver] for the user
  /// [caller] alone. The socket is made readable and writable by its group,
  /// the journey user's own, which is how the airlock's user reaches it; a
  /// socket file nothing listens on is replaced.
  static Future<ProgramDriverService> start(
    ProgramDriver driver,
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
      void send(ProgramMessage message) => socket.add(
        utf8.encode('${jsonEncode(encodeProgramMessage(message))}\n'),
      );
      send(Finished(await _run(tooLarge ? null : request.takeBytes(), send)));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// Runs the start in [request] (null: it was too large), reporting
  /// through [send].
  Future<Outcome<ExecResult>> _run(
    Uint8List? request,
    void Function(ProgramMessage) send,
  ) async {
    if (request == null) return const Refused('request too large');
    final ProgramName program;
    final Args args;
    try {
      (program, args) = decodeStart(jsonDecode(utf8.decode(request)));
    } on FormatException catch (e) {
      return Refused('not a start: ${e.message}');
    }
    return _driver.start(
      program,
      args,
      report: (progress) => send(Reported(progress)),
    );
  }
}

/// A [ProgramDriver] in another process: sends each start to the service at
/// [socket] and reports what comes back as it comes.
final class SocketProgramDriver implements ProgramDriver {
  SocketProgramDriver(this.socket);

  final File socket;

  /// A run whose connection ends before its [Finished] is [Refused] when
  /// nothing was reported, so the program never started; once something
  /// was, it is [Killed] with what it had printed, though the program may
  /// still be running. The contract has no outcome for a run lost track of.
  @override
  Future<Outcome<ExecResult>> start(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    var started = false;
    Outcome<ExecResult> lost(String why) => started
        ? Ran(
            Killed(
              'lost the program driver mid-run ($why); '
              'the program may still be running',
              stdout: '$stdout',
              stderr: '$stderr',
            ),
          )
        : Refused('program driver: $why');
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      s.add(utf8.encode(jsonEncode(encodeStart(program, args))));
      await s.close();
      await for (final line
          in s
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        switch (decodeProgramMessage(jsonDecode(line))) {
          case Reported(:final progress):
            started = true;
            if (progress case Printed(:final channel, :final text)) {
              (channel == Channel.stdout ? stdout : stderr).write(text);
            }
            report(progress);
          case Finished(:final outcome):
            return outcome;
        }
      }
      return lost(started ? 'connection closed' : 'refused caller');
    } on SocketException catch (e) {
      return lost(e.message);
    } on FormatException catch (e) {
      return lost('bad answer: ${e.message}');
    }
  }
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
