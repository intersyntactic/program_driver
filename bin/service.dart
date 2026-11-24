/// Runs the program driver (see `ProgramDriver`), as the suit a trajectory's
/// agent wears:
///
///     PROGRAM_DRIVER_SOCKET=/run/program/suit-3/driver.sock \
///       PROGRAM_DRIVER_CALLER=airlock \
///       PROGRAM_DRIVER_ROOT=/home/suit-3 \
///       PROGRAM_DRIVER_PROGRAMS=/usr/local/lib/intersyntactic/programs \
///       dart run is_program_driver:service
///
/// `PROGRAM_DRIVER_CALLER` is the one user, by name or id, whose starts it
/// carries out. `PROGRAM_DRIVER_PROGRAMS` is the box's programs folder (see
/// `InstalledPrograms`): it runs those programs and no others.
/// `PROGRAM_DRIVER_TIMEOUT`, in seconds, is how long a program may run before
/// its group is killed: 600 unless set. `PROGRAM_DRIVER_MAX_OUTPUT_BYTES` is
/// the most a program may print on stdout, and on stderr, before its group is
/// killed: 8 MiB unless set.
///
/// Exits 78 when it cannot start as configured. On SIGTERM or SIGINT it
/// kills every program still running, group and all, and closes.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_program_driver/is_program_driver.dart';
import 'package:is_program_driver/src/system_program.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, root, programsFolder] = [
    for (final name in [
      'PROGRAM_DRIVER_SOCKET',
      'PROGRAM_DRIVER_CALLER',
      'PROGRAM_DRIVER_ROOT',
      'PROGRAM_DRIVER_PROGRAMS',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final number = _uidOf(caller) ?? _fail('no user $caller');
  final uid =
      UserId.parse(number) ??
      _fail('PROGRAM_DRIVER_CALLER: uid $number can never be the caller');
  if (!Directory(root).existsSync()) _fail('no folder $root');
  final timeout = switch (env['PROGRAM_DRIVER_TIMEOUT']) {
    null => const Duration(minutes: 10),
    final raw => switch (int.tryParse(raw)) {
      final seconds? when seconds > 0 => Duration(seconds: seconds),
      _ => _fail('PROGRAM_DRIVER_TIMEOUT: not a number of seconds ($raw)'),
    },
  };
  final maxOutputBytes = switch (env['PROGRAM_DRIVER_MAX_OUTPUT_BYTES']) {
    null => ProgramDriver.defaultMaxOutputBytes,
    final raw => switch (int.tryParse(raw)) {
      final bytes? when bytes > 0 => bytes,
      _ => _fail(
        'PROGRAM_DRIVER_MAX_OUTPUT_BYTES: not a number of bytes ($raw)',
      ),
    },
  };
  final self = _uidOf(null) ?? _fail('cannot read its own user');
  final InstalledPrograms programs;
  try {
    programs = InstalledPrograms.read(
      Directory(programsFolder),
      driverUser: self,
    );
  } on UnsafeProgramsFolder catch (e) {
    _fail('$e');
  }
  final ProgramDriver driver;
  try {
    driver = await ProgramDriver.start(
      root: Directory(root),
      programs: programs,
      caller: uid,
      socket: File(socket),
      timeout: timeout,
      maxOutputBytes: maxOutputBytes,
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, in $root, '
    'timeout ${timeout.inSeconds}s, max output $maxOutputBytes bytes, '
    'running ${(programs.names.map((n) => '$n').toList()..sort()).join(' ')}',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await driver.close();
  exit(0);
}

/// [user]'s uid, by name or id; this process's own when [user] is null.
int? _uidOf(String? user) {
  if (user != null) {
    if (int.tryParse(user) case final uid?) return uid;
  }
  final id = SystemProgram.id.find() ?? _fail(SystemProgram.id.missing);
  final r = Process.runSync(id.path, ['-u', ?user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

Never _fail(String why) {
  stderr.writeln('is_program_driver service: $why');
  exit(78);
}
