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

/// [names] as a sorted JSON list, so one set always encodes the same.
Object? encodeProgramNames(Set<ProgramName> names) =>
    [for (final n in names) n.value]..sort();

/// The set [encodeProgramNames] wrote. Throws [FormatException] for
/// anything else, a duplicate included.
Set<ProgramName> decodeProgramNames(Object? json) {
  if (json is! List<Object?>) {
    throw const FormatException('program names: not a list');
  }
  final names = <ProgramName>{};
  for (final raw in json) {
    final name = raw is String ? ProgramName.parse(raw) : null;
    if (name == null) {
      throw FormatException('program names: not a program\'s name: $raw');
    }
    if (!names.add(name)) {
      throw FormatException('program names: $name twice');
    }
  }
  return names;
}
