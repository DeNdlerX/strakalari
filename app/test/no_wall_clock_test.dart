import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PLAN §3.3: write `clock.now()`, never `DateTime.now()`, so tests can fix
/// the time (the single-instance token now comes from Random.secure()).
void main() {
  test('app code reads the time from package:clock', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (line.contains('DateTime.now()')) offenders.add('$path:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
