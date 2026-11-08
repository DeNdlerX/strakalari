import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/audit.dart';
import 'package:strakalari_core/src/platform/packaging.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('audit_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('auditRoundtrip', () {
    test('roundtripNewestFirst', () {
      expect(recent(), isEmpty);
      expect(record('excuse', 'sent', 'auto', '01.09.2026'), isTrue);
      expect(record('lunch', 'dry_run', 'manual', '02.09.2026: order'),
          isTrue);
      final items = recent();
      expect(items.map((i) => i['kind']).toList(), ['lunch', 'excuse']);
      expect(items[1]['source'], 'auto');
      expect(hasDryRun('lunch'), isTrue);
      expect(hasDryRun('excuse'), isFalse);
    });

    test('skipsCorruptLines', () {
      expect(record('excuse', 'sent', 'manual', 'x'), isTrue);
      File(historyPath())
          .writeAsStringSync('{not json\n', mode: FileMode.append);
      expect(recent(), hasLength(1));
    });
  });

  group('describeExcuse', () {
    test('hasNoText', () {
      final label = describeExcuse({
        'type': 'days and hours',
        'starting_day': '01.09.2026',
        'ending_day': '01.09.2026',
        'starting_lesson': 2,
        'ending_lesson': 4,
      });
      expect(label, '01.09.2026 (2.–4.)');
    });
  });
}
