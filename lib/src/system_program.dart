import 'dart:io';

/// The folders the driver finds its own helpers in, in order. Only root can
/// write them, so what is found there is the system's own.
const systemFolders = ['/usr/bin', '/bin'];

/// The programs the driver runs for itself, never for a caller.
enum SystemProgram {
  stat,
  chmod,
  id;

  /// The first file named after this program in [folders], or null when
  /// none has it. Never looked for on the PATH, which would let whoever sets
  /// it choose what runs.
  File? find({List<String> folders = systemFolders}) {
    for (final folder in folders) {
      final program = File('$folder/$name');
      if (program.existsSync()) return program;
    }
    return null;
  }

  /// Why [find] found nothing, for an error message.
  String get missing => 'no $name in ${systemFolders.join(' or ')}';
}
