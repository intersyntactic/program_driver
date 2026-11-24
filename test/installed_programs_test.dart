import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_program_driver/is_program_driver.dart';
import 'package:test/test.dart';

final me = int.parse(Process.runSync('id', ['-u']).stdout.toString().trim());

/// 0755 and 0644 in octal.
const executable = 493;
const readable = 420;

void main() {
  late Directory dir;
  late Directory programs;

  /// [path]s owned by root and 0755, except those in [changed].
  FileOwnership Function(String) statWith([
    Map<String, FileOwnership> changed = const {},
  ]) =>
      (path) => changed[path] ?? (owner: 0, mode: executable);

  InstalledPrograms read([Map<String, FileOwnership> changed = const {}]) =>
      InstalledPrograms.read(programs, driverUser: me, stat: statWith(changed));

  Matcher unsafe(String why) => throwsA(
    isA<UnsafeProgramsFolder>().having((e) => e.why, 'why', contains(why)),
  );

  setUp(() async {
    dir = Directory(
      (await Directory.systemTemp.createTemp('ip')).resolveSymbolicLinksSync(),
    );
    programs = await Directory('${dir.path}/programs').create();
  });
  tearDown(() => dir.delete(recursive: true));

  test('names each entry, a symlink or the program itself', () async {
    await Link('${programs.path}/sh').create('/bin/sh');
    await File('${programs.path}/teams-message').writeAsString('');
    final installed = read();
    expect(installed.names, {
      ProgramName.parse('sh')!,
      ProgramName.parse('teams-message')!,
    });
    expect(installed.pathOf(ProgramName.parse('sh')!), '${programs.path}/sh');
    expect(installed.pathOf(ProgramName.parse('cat')!), isNull);
  });

  test('an empty folder runs nothing', () {
    expect(read().names, isEmpty);
  });

  test('refuses a folder that is not there', () {
    expect(
      () => InstalledPrograms.read(
        Directory('${dir.path}/none'),
        driverUser: me,
        stat: statWith(),
      ),
      unsafe('no folder'),
    );
  });

  test("refuses a folder owned by the driver's user", () {
    expect(
      () => read({programs.path: (owner: me, mode: executable)}),
      unsafe("owned by the driver's user"),
    );
  });

  test('refuses a folder above it that its group or anyone may write', () {
    expect(
      () => read({dir.path: (owner: 0, mode: 511)}), // 0777
      unsafe('writable by its group or anyone'),
    );
  });

  test("refuses a program the driver's user could change", () async {
    final teams = File('${dir.path}/teams-message')..writeAsStringSync('');
    await Link('${programs.path}/teams-message').create(teams.path);
    expect(
      () => read({teams.path: (owner: me, mode: executable)}),
      unsafe("owned by the driver's user"),
    );
  });

  test('refuses a folder it cannot list', () async {
    await Process.run('chmod', ['000', programs.path]);
    addTearDown(() => Process.run('chmod', ['755', programs.path]));
    expect(read, unsafe('cannot list'));
  });

  test("refuses a path whose owner it cannot read", () {
    expect(
      () => InstalledPrograms.read(
        programs,
        driverUser: me,
        stat: (path) => path == dir.path
            ? throw FileSystemException('stat: no such user', path)
            : (owner: 0, mode: executable),
      ),
      unsafe('cannot read who owns ${dir.path}'),
    );
  });

  test('refuses an entry that leads nowhere', () async {
    await Link('${programs.path}/gone').create('${dir.path}/gone');
    expect(read, unsafe('leads nowhere'));
  });

  test('refuses an entry that is a folder', () async {
    await Directory('${programs.path}/tools').create();
    expect(read, unsafe('not a file'));
  });

  test('refuses a program nobody may execute', () async {
    final notes = File('${programs.path}/notes')..writeAsStringSync('');
    expect(
      () => read({notes.path: (owner: 0, mode: readable)}),
      unsafe('not executable'),
    );
  });

  test("refuses an entry whose name is not a program's", () async {
    await Link('${programs.path}/two words').create('/bin/sh');
    expect(read, unsafe("not a program's name"));
  });

  test('reads ownership from the real stat, refusing a test folder', () {
    // Run for real: the folder is this test user's own.
    expect(
      () => InstalledPrograms.read(programs, driverUser: me),
      unsafe("owned by the driver's user"),
    );
  });
}
