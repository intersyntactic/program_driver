import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

/// The airlock's connection to the [ProgramDriver] at [socket]: each program
/// the airlock passes on is sent there, and what comes back is reported as
/// it comes.
final class ProgramDriverSocket implements RunsPrograms {
  ProgramDriverSocket(this.socket);

  final File socket;

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
