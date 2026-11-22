import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'request.dart';

/// The connection to the [ProgramDriver] at [socket]: each program the
/// airlock passes on is sent there, and what comes back is reported as it
/// comes; and loop_launcher asks it which programs it runs.
final class ProgramDriverSocket
    implements RunsPrograms, ListsInstalledPrograms {
  ProgramDriverSocket(this.socket);

  final File socket;

  /// The programs the driver runs, as it loaded them when it started.
  /// Throws [InstalledProgramsUnknown] when it cannot be asked or does not
  /// answer with them.
  @override
  Future<Set<ProgramName>> installedPrograms() async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      s.add(utf8.encode(jsonEncode(const ListInstalledPrograms().toJson())));
      await s.close();
      final answer = await utf8.decoder.bind(s).join();
      if (!answer.endsWith('\n')) {
        throw const InstalledProgramsUnknown('no answer');
      }
      return decodeProgramNames(jsonDecode(answer));
    } on SocketException catch (e) {
      throw InstalledProgramsUnknown(e.message);
    } on FormatException catch (e) {
      throw InstalledProgramsUnknown('bad answer: ${e.message}');
    }
  }

  /// [Refused] only when the driver could not be reached, so nothing was
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
      s.add(utf8.encode(jsonEncode(RunProgram(program, args).toJson())));
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

/// The driver was asked which programs it runs and did not say, because
/// [why].
final class InstalledProgramsUnknown implements Exception {
  const InstalledProgramsUnknown(this.why);

  final String why;

  @override
  String toString() => 'program driver: installed programs unknown: $why';
}
