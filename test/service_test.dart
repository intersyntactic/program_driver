import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_program_driver/service.dart';
import 'package:test/test.dart';

/// Prints its arguments on stdout and its stdin on stderr, then exits with
/// the number of arguments.
final class Echo implements ProgramDriver {
  final started = <(ProgramName, Args)>[];

  @override
  Future<Outcome<ExecResult>> start(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    started.add((program, args));
    final out = args.args.join(' ');
    final err = args.stdin ?? '';
    report(Printed(Channel.stdout, out));
    report(Printed(Channel.stderr, err));
    return Ran(Exited(args.args.length, stdout: out, stderr: err));
  }
}

final me = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());
final git = ProgramName.parse('git')!;

void main() {
  late Directory dir;
  late File socket;
  late Echo driver;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    dir = await Directory('/tmp').createTemp('pd');
    socket = File('${dir.path}/s');
    driver = Echo();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<List<String>> raw(String request) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(request));
    await s.close();
    return const LineSplitter().convert(await utf8.decoder.bind(s).join());
  }

  test('starts a program for its caller, reporting what it prints', () async {
    final service = await ProgramDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final reported = <Progress>[];
    final out = await SocketProgramDriver(socket).start(
      git,
      Args(['status', '-s'], stdin: 'in', inFolder: RelativePath('trees/a')),
      report: reported.add,
    );
    final exited = (out as Ran<ExecResult>).output as Exited;
    expect(exited.exitCode, 2);
    expect(exited.stdout, 'status -s');
    expect(exited.stderr, 'in');
    expect(
      [for (final p in reported.cast<Printed>()) (p.channel, p.text)],
      [(Channel.stdout, 'status -s'), (Channel.stderr, 'in')],
    );
    final (program, args) = driver.started.single;
    expect(program, git);
    expect(args.inFolder, RelativePath('trees/a'));
  });

  test('answers a line per message, the last one finished', () async {
    final service = await ProgramDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final lines = await raw(jsonEncode(encodeStart(git, Args(['x']))));
    expect(
      [for (final l in lines) (jsonDecode(l) as Map)['kind']],
      ['reported', 'reported', 'finished'],
    );
  });

  test('refuses what is not a start, and starts nothing', () async {
    final service = await ProgramDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final lines = await raw('{"program":"git status"}');
    final finished = decodeProgramMessage(jsonDecode(lines.single)) as Finished;
    expect((finished.outcome as Refused).why, startsWith('not a start'));
    expect(driver.started, isEmpty);
  });

  test('answers nobody but its caller, and starts nothing', () async {
    final service = await ProgramDriverService.start(driver, me + 1, socket);
    addTearDown(service.close);
    final out = await SocketProgramDriver(socket).start(
      git,
      Args(['status']),
      report: (_) => fail('reported to a refused caller'),
    );
    // Why depends on whether the hang-up lands before or after the write.
    expect(out, isA<Refused>());
    expect(driver.started, isEmpty);
  });

  test('its socket is readable and writable by owner and group only', () async {
    final service = await ProgramDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(socket.statSync().modeString(), 'rw-rw----');
  });
}
