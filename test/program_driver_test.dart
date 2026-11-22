import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_program_driver/is_program_driver.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

final me = UserId.parse(
  int.parse((Process.runSync('id', ['-u']).stdout as String).trim()),
)!;
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
    await Link('${dir.path}/programs/sh').create('/bin/sh', recursive: true);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<ProgramDriver> start({
    UserId? caller,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputBytes = ProgramDriver.defaultMaxOutputBytes,
    SocketUserReader? socketUserReader,
  }) async {
    final driver = await ProgramDriver.start(
      root: root,
      // A test's folders are its own user's, under a /tmp anyone may write,
      // so the folder is read as if root had installed it.
      programs: InstalledPrograms.read(
        Directory('${dir.path}/programs'),
        driverUser: me.number,
        stat: (_) => (owner: 0, mode: 493), // 0755
      ),
      caller: caller ?? me,
      socket: socket,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes,
      socketUserReader: socketUserReader,
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
      jsonEncode({
        'kind': 'run',
        'programToRun': encodeProgramToRun(sh, Args(['-c', 'echo x'])),
      }),
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
    await start(caller: UserId.parse(me.number + 1));
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

  test('turns away a peer whose user cannot be read', () async {
    // The kernel answers with fewer bytes than a ucred holds.
    await start(
      socketUserReader: SocketUserReader(
        kernel: Kernel.linux,
        readOption: (_, _) => Uint8List(0),
      ),
    );
    await expectLater(
      ProgramDriverSocket(socket).runProgram(
        sh,
        Args(['-c', 'touch ran']),
        report: (_) => fail('reported to an unknown peer'),
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

  test('refuses a program not installed, though it is on the PATH', () async {
    await start();
    final out = await ProgramDriverSocket(socket).runProgram(
      ProgramName.parse('cat')!,
      Args([]),
      report: (_) => fail('reported for a program never started'),
    );
    expect((out as Refused).why, contains('installed'));
  });

  test('refuses a name holding a slash, which finds no entry', () async {
    await start();
    final out = await ProgramDriverSocket(socket).runProgram(
      ProgramName.parse('/bin/sh')!,
      Args(['-c', 'touch ran']),
      report: (_) {},
    );
    expect(out, isA<Refused>());
    expect(File('${root.path}/ran').existsSync(), isFalse);
  });

  test('says which programs it runs', () async {
    await start();
    expect(await ProgramDriverSocket(socket).installedPrograms(), {sh});
  });

  test('cannot say which programs it runs when none is listening', () async {
    await expectLater(
      ProgramDriverSocket(socket).installedPrograms(),
      throwsA(isA<InstalledProgramsUnknown>()),
    );
  });

  /// Runs `sh -c [script]`, returning its outcome and what it reported.
  Future<(Outcome<ExecResult>, List<Printed>)> runSh(String script) async {
    final reported = <Printed>[];
    final out = await ProgramDriverSocket(socket).runProgram(
      sh,
      Args(['-c', script]),
      report: (p) => reported.add(p as Printed),
    );
    return (out, reported);
  }

  String printed(List<Printed> reported, Channel channel) => [
    for (final p in reported)
      if (p.channel == channel) p.text,
  ].join();

  test('kills a program that prints past its limit, keeping only that '
      'much', () async {
    await start(maxOutputBytes: 10);
    final stopwatch = Stopwatch()..start();
    final (out, reported) = await runSh(
      'printf 0123456789abcdef; sleep 30; touch survived',
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    final killed = (out as Ran<ExecResult>).output as Killed;
    expect(killed.why, 'printed more than 10 bytes on stdout');
    expect(killed.stdout, '0123456789');
    expect(printed(reported, Channel.stdout), '0123456789');
    expect(File('${root.path}/survived').existsSync(), isFalse);
  });

  test('lets a program print exactly its limit', () async {
    await start(maxOutputBytes: 10);
    final (out, _) = await runSh('printf 0123456789');
    final exited = (out as Ran<ExecResult>).output as Exited;
    expect(exited.exitCode, 0);
    expect(exited.stdout, '0123456789');
  });

  test('cuts what it keeps where a character ends', () async {
    // `a` is one byte and `é` two, so four bytes end inside the second `é`.
    await start(maxOutputBytes: 4);
    final (out, reported) = await runSh('printf aéé');
    final killed = (out as Ran<ExecResult>).output as Killed;
    expect(killed.stdout, 'aé');
    expect(printed(reported, Channel.stdout), 'aé');
  });

  test('holds stderr to the same limit', () async {
    await start(maxOutputBytes: 10);
    final (out, reported) = await runSh('printf 0123456789abcdef >&2');
    final killed = (out as Ran<ExecResult>).output as Killed;
    expect(killed.why, 'printed more than 10 bytes on stderr');
    expect(killed.stderr, '0123456789');
    expect(printed(reported, Channel.stderr), '0123456789');
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
