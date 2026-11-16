/// Runs the program driver as a service (see
/// `package:is_program_driver/service.dart`), as the journey user:
///
///     PROGRAM_DRIVER_SOCKET=/run/program-contained/journey-3/driver.sock \
///       PROGRAM_DRIVER_CALLER=intersyntactic-airlock \
///       PROGRAM_DRIVER_ROOT=/home/journey-3 \
///       dart run is_program_driver:service
///
/// `PROGRAM_DRIVER_CALLER` is the one user, by name or id, whose starts it
/// carries out. `PROGRAM_DRIVER_TIMEOUT`, in seconds, is how long a program
/// may run before its group is killed: 600 unless set.
///
/// Exits 78 when it cannot start as configured. On SIGTERM or SIGINT it
/// kills every program still running, group and all, and closes.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_program_driver/is_program_driver.dart';
import 'package:is_program_driver/service.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, root] = [
    for (final name in [
      'PROGRAM_DRIVER_SOCKET',
      'PROGRAM_DRIVER_CALLER',
      'PROGRAM_DRIVER_ROOT',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final uid = _uidOf(caller) ?? _fail('no user $caller');
  if (!Directory(root).existsSync()) _fail('no folder $root');
  final timeout = switch (env['PROGRAM_DRIVER_TIMEOUT']) {
    null => const Duration(minutes: 10),
    final raw => switch (int.tryParse(raw)) {
      final seconds? when seconds > 0 => Duration(seconds: seconds),
      _ => _fail('PROGRAM_DRIVER_TIMEOUT: not a number of seconds ($raw)'),
    },
  };
  final ProgramDriverService service;
  try {
    service = await ProgramDriverService.start(
      TreeProgramDriver(Directory(root), timeout: timeout),
      uid,
      File(socket),
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, in $root, '
    'timeout ${timeout.inSeconds}s',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await service.close();
  await TreeProgramDriver.killRunning();
  exit(0);
}

int? _uidOf(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

Never _fail(String why) {
  stderr.writeln('is_program_driver service: $why');
  exit(78);
}
