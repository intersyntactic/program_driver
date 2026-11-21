import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_program_driver/is_program_driver.dart';
import 'package:test/test.dart';

final me = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());
final sh = ProgramName.parse('sh')!;

void main() {
  late Directory dir;
  late Directory root;
  late File socket;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    dir = await Directory('/tmp').createTemp('pd');
    root = await Directory('${dir.path}/home').create();
    socket = File('${dir.path}/s');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<ProgramDriver> start({
    int? caller,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final driver = await ProgramDriver.start(
      root: root,
      caller: caller ?? me,
      socket: socket,
      timeout: timeout,
    );
    addTearDown(driver.close);
    return driver;
  }

  Future<List<String>> raw(String request) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(request));
    await s.close();
    return const LineSplitter().convert(await utf8.decoder.bind(s).join());
  }

  test('runs a program in its folder, reporting what it prints', () async {
    await start();
    await Directory('${root.path}/trees/a').create(recursive: true);
    final reported = <Progress>[];
    final out = await ProgramDriverSocket(socket).runProgram(
      sh,
      Args(
        ['-c', r'basename "$PWD"; cat >&2; exit 3'],
        stdin: 'in',
        inFolder: RelativePath('trees/a'),
      ),
      report: reported.add,
    );
    final exited = (out as Ran<ExecResult>).output as Exited;
    expect(exited.exitCode, 3);
    expect(exited.stdout, 'a\n');
    expect(exited.stderr, 'in');
    expect([
      for (final p in reported.cast<Printed>()) (p.channel, p.text),
    ], unorderedEquals([(Channel.stdout, 'a\n'), (Channel.stderr, 'in')]));
  });

  test('answers a line per message, the last one finished', () async {
    await start();
    final lines = await raw(
      jsonEncode(encodeProgramToRun(sh, Args(['-c', 'echo x']))),
    );
    expect(
      [for (final l in lines) (jsonDecode(l) as Map)['kind']],
      ['reported', 'finished'],
    );
  });

  test('refuses a folder outside its root, and starts nothing', () async {
    await start();
    final out = await ProgramDriverSocket(socket).runProgram(
      sh,
      Args(['-c', 'touch ran'], inFolder: RelativePath('..')),
      report: (_) {},
    );
    expect(out, isA<Refused>());
    expect(File('${dir.path}/ran').existsSync(), isFalse);
  });

  test('kills a program that runs past its timeout', () async {
    await start(timeout: const Duration(seconds: 1));
    final out = await ProgramDriverSocket(socket)
        .runProgram(sh, Args(['-c', 'sleep 30']), report: (_) {});
    expect((out as Ran<ExecResult>).output, isA<Killed>());
  });

  test('refuses what is not a start', () async {
    await start();
    final lines = await raw('{"program":"sh -c \'touch ran\'"}');
    final finished = decodeProgramMessage(
      jsonDecode(lines.single),
      decodeExecResult,
    ) as Finished<ExecResult>;
    expect((finished.outcome as Refused).why, startsWith('not a start'));
  });

  test('answers nobody but its caller, and starts nothing', () async {
    await start(caller: me + 1);
    // From the caller's side a hang-up after the start is sent is a run
    // whose outcome never came back, which it cannot tell from a refusal.
    await expectLater(
      ProgramDriverSocket(socket).runProgram(
        sh,
        Args(['-c', 'touch ran']),
        report: (_) => fail('reported to a refused caller'),
      ),
      throwsA(isA<OutcomeUnknown>()),
    );
    expect(File('${root.path}/ran').existsSync(), isFalse);
  });

  test('kills every program still running as it closes', () async {
    final driver = await start();
    final started = Completer<void>();
    final run = ProgramDriverSocket(socket).runProgram(
      sh,
      Args(['-c', 'echo started; sleep 30; touch survived']),
      report: (_) {
        if (!started.isCompleted) started.complete();
      },
    );
    await started.future;
    final stopwatch = Stopwatch()..start();
    await driver.close();
    await run.then((_) {}, onError: (Object _) {});
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(File('${root.path}/survived').existsSync(), isFalse);
  });

  test('is refused when no driver is listening', () async {
    final out = await ProgramDriverSocket(socket)
        .runProgram(sh, Args(['-c', 'true']), report: (_) {});
    expect(out, isA<Refused>());
  });

  test('its socket is readable and writable by owner and group only', () async {
    await start();
    expect(socket.statSync().modeString(), 'rw-rw----');
  });
}
