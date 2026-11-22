import 'package:is_effects/is_effects.dart';

/// What the airlock asks the program driver, as it crosses the socket.
sealed class ProgramDriverRequest {
  const ProgramDriverRequest();

  static ProgramDriverRequest fromJson(Object? json) => switch (json) {
    {'kind': 'run', 'programToRun': final Object? programToRun} =>
      switch (decodeProgramToRun(programToRun)) {
        (final program, final args) => RunProgram(program, args),
      },
    {'kind': 'list'} => const ListInstalledPrograms(),
    _ => throw const FormatException(
      'not {"kind": "run", "programToRun"} or {"kind": "list"}',
    ),
  };

  Object? toJson();
}

/// Run [program] with [args]; the answer is a line per [ProgramMessage].
final class RunProgram extends ProgramDriverRequest {
  const RunProgram(this.program, this.args);

  final ProgramName program;
  final Args args;

  @override
  Object? toJson() => {
    'kind': 'run',
    'programToRun': encodeProgramToRun(program, args),
  };
}

/// Say which programs are installed; the answer is one line, their names
/// as a sorted JSON list.
final class ListInstalledPrograms extends ProgramDriverRequest {
  const ListInstalledPrograms();

  @override
  Object? toJson() => {'kind': 'list'};
}
