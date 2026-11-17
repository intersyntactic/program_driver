import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_executor/is_executor.dart' as executor;

/// [RunsPrograms] for one root, the suit's home: each program it
/// starts runs in the folder its [Args.inFolder] names under the root, which
/// must resolve inside it, leads a process group of its own, and is killed
/// with everything it started when it runs past [timeout].
///
/// A start reaches it only once the airlock has decided and recorded it, so
/// it asks nobody. Programs run as this process's OS user, with everything
/// that user can do.
final class TreeProgramDriver implements RunsPrograms {
  /// [timeout] is how long a program may run before its group is killed, and
  /// [quiet], when given, how long it may print nothing once it has started
  /// printing.
  TreeProgramDriver(Directory root, {required this.timeout, this.quiet})
    : _executor = executor.Executor(
        root: root,
        consent: _decidedByTheAirlock,
        timeout: timeout,
        onStarted: (pid, _) => _running.add(pid),
        onExited: _running.remove,
      );

  final Duration timeout;
  final Duration? quiet;
  final executor.Executor _executor;

  /// The process groups of the programs running now, by their leaders' pids.
  static final _running = <int>{};

  /// The executor's consent, already given: a start reaches this driver only
  /// once the airlock's decision is recorded, and asking again would put a
  /// decided run to the person a second time.
  static Future<bool> _decidedByTheAirlock(executor.ExecRequest _) async =>
      true;

  /// Reports what the program prints as it prints it, and returns only once
  /// all of it has been reported, so nothing is reported after the outcome.
  @override
  Future<Outcome<ExecResult>> runProgram(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final running = _executor.start(
      [program.value, ...args.args],
      input: args.stdin,
      workingSubdir: args.inFolder.value,
      quiet: quiet,
      taps: executor.ExecTaps.none,
    );
    final (start, _, _) = await (
      running.result,
      running.stdout.forEach((t) => report(Printed(Channel.stdout, t))),
      running.stderr.forEach((t) => report(Printed(Channel.stderr, t))),
    ).wait;
    return _outcome(start);
  }

  Outcome<ExecResult> _outcome(executor.ExecStart start) => switch (start) {
    executor.ExecStarted(:final result) => Ran(switch (result) {
      executor.ExecResult(:final silentFor?) => Killed(
        'printed nothing for ${silentFor.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      executor.ExecResult(timedOut: true) => Killed(
        'timed out after ${timeout.inSeconds}s',
        stdout: result.stdout,
        stderr: result.stderr,
      ),
      _ => Exited(
        result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      ),
    }),
    executor.ExecNotStarted(:final why) => Refused(why),
  };

  /// Kills the process group of every program running now, as the service
  /// stops, so none outlives it.
  static Future<void> killRunning() async {
    for (final leader in _running.toList()) {
      await Process.run('kill', ['-KILL', '--', '-$leader']);
    }
  }
}
