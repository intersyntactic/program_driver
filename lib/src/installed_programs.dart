import 'dart:io';

import 'package:is_effects/is_effects.dart';

/// Who owns a file and its permission bits, as `stat` reports them.
typedef FileOwnership = ({int owner, int mode});

/// The programs a box has installed for its drivers: one folder whose every
/// entry is named after the program it runs, and is that program or a
/// symlink to it.
///
/// Read once, as the driver starts, so the list loop_launcher checks a
/// trajectory against as it starts it is the list the driver keeps to for
/// its whole life.
/// A name is found only as an entry of the folder, never on the PATH, so a
/// name holding a `/` finds nothing.
final class InstalledPrograms {
  InstalledPrograms._(this._entries);

  final Map<ProgramName, String> _entries;

  /// The names it runs.
  Set<ProgramName> get names => _entries.keys.toSet();

  /// The path to start for [program], or null when it is not installed.
  String? pathOf(ProgramName program) => _entries[program];

  /// Reads [folder] for a driver running as the user [driverUser].
  ///
  /// Throws [UnsafeProgramsFolder] when that user could change what runs:
  /// when it owns, or the folder's group or everyone may write, the folder,
  /// any entry's program, or any folder above either. It also throws for an
  /// entry that is not an executable file once its symlinks are followed,
  /// or whose name is not a program's name, and when the folder cannot be
  /// listed or a path's owner cannot be read.
  static InstalledPrograms read(
    Directory folder, {
    required int driverUser,
    FileOwnership Function(String path) stat = _stat,
  }) {
    FileOwnership ownership(String path) {
      try {
        return stat(path);
      } on FileSystemException catch (e) {
        throw UnsafeProgramsFolder('cannot read who owns $path: ${e.message}');
      }
    }

    void unchangeable(String path) {
      for (var p = path; ; p = File(p).parent.path) {
        final (:owner, :mode) = ownership(p);
        if (owner == driverUser) {
          throw UnsafeProgramsFolder('$p is owned by the driver\'s user');
        }
        if (mode & _groupOrOtherWrite != 0) {
          throw UnsafeProgramsFolder('$p is writable by its group or anyone');
        }
        if (File(p).parent.path == p) return;
      }
    }

    final String resolvedFolder;
    try {
      resolvedFolder = folder.resolveSymbolicLinksSync();
    } on FileSystemException {
      throw UnsafeProgramsFolder('no folder ${folder.path}');
    }
    unchangeable(resolvedFolder);
    final List<FileSystemEntity> listed;
    try {
      listed = Directory(resolvedFolder).listSync();
    } on FileSystemException catch (e) {
      throw UnsafeProgramsFolder(
        'cannot list $resolvedFolder: ${e.osError?.message ?? e.message}',
      );
    }
    final entries = <ProgramName, String>{};
    for (final entry in listed) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      final program =
          ProgramName.parse(name) ??
          (throw UnsafeProgramsFolder('$name is not a program\'s name'));
      final String target;
      try {
        target = entry.resolveSymbolicLinksSync();
      } on FileSystemException {
        throw UnsafeProgramsFolder('${entry.path} leads nowhere');
      }
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.file) {
        throw UnsafeProgramsFolder('${entry.path} is not a file');
      }
      if (ownership(target).mode & _anyExecute == 0) {
        throw UnsafeProgramsFolder('${entry.path} is not executable');
      }
      unchangeable(target);
      entries[program] = entry.path;
    }
    return InstalledPrograms._(Map.unmodifiable(entries));
  }
}

/// Permission bits: 0022 and 0111 in octal.
const _groupOrOtherWrite = 0x12;
const _anyExecute = 0x49;

/// A programs folder the driver will not start with, because [why].
final class UnsafeProgramsFolder implements Exception {
  const UnsafeProgramsFolder(this.why);

  final String why;

  @override
  String toString() => 'programs folder: $why';
}

/// [path]'s owner and permission bits, from `stat`.
FileOwnership _stat(String path) {
  final r = Process.runSync(
    'stat',
    Platform.isMacOS ? ['-f', '%u %Lp', path] : ['-c', '%u %a', path],
  );
  final fields = r.exitCode == 0
      ? r.stdout.toString().trim().split(' ')
      : const <String>[];
  if (fields case [final owner, final mode]) {
    if ((int.tryParse(owner), int.tryParse(mode, radix: 8)) case (
      final owner?,
      final mode?,
    )) {
      return (owner: owner, mode: mode);
    }
  }
  throw FileSystemException('stat: ${r.stderr}', path);
}
