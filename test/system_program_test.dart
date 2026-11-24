import 'dart:io';

import 'package:is_program_driver/src/system_program.dart';
import 'package:test/test.dart';

void main() {
  test('finds each helper in a system folder', () {
    for (final program in SystemProgram.values) {
      final found = program.find();
      expect(found, isNotNull, reason: '${program.name} not found');
      expect(systemFolders, contains(found!.parent.path));
    }
  });

  test('finds nothing in a folder without it, even when the PATH has it', () {
    final empty = Directory.systemTemp.createTempSync('sys');
    addTearDown(() => empty.deleteSync());
    expect(SystemProgram.stat.find(folders: [empty.path]), isNull);
  });

  test('takes the first folder that has it', () {
    final first = Directory.systemTemp.createTempSync('sys');
    addTearDown(() => first.deleteSync(recursive: true));
    File('${first.path}/id').writeAsStringSync('');
    expect(
      SystemProgram.id.find(folders: [first.path, '/usr/bin'])!.path,
      '${first.path}/id',
    );
  });
}
