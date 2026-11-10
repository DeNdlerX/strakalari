import 'dart:async';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_save_warnings_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('pyRepr helper', () {
    test('formats python representation', () {
      expect(core.pyRepr(null), equals('None'));
      expect(core.pyRepr(true), equals('True'));
      expect(core.pyRepr(false), equals('False'));
      expect(core.pyRepr(42), equals('42'));
      expect(core.pyRepr('simple_key'), equals("'simple_key'"));
      expect(core.pyRepr("it's"), equals('"it\'s"'));
      expect(core.pyRepr('line\nbreak'), equals(r"'line\nbreak'"));
    });
  });

  group('AppState.save warnings', () {
    test('prints warning on invalid config update', () {
      final state = AppState();
      final logs = <String>[];

      runZoned(
        () {
          final ok = state.save({'excuse_mode': 'invalid_choice'});
          expect(ok, isFalse);
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            logs.add(line);
          },
        ),
      );

      expect(
        logs.any((l) =>
            l.startsWith("Warning: ignoring invalid config update 'excuse_mode':")),
        isTrue,
      );
    });

    test('prints warning on listener failure', () {
      final state = AppState();
      state.configListeners.add(() {
        throw StateError('broken listener');
      });
      final logs = <String>[];

      runZoned(
        () {
          final ok = state.save({'check_interval_minutes': 30});
          expect(ok, isTrue);
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            logs.add(line);
          },
        ),
      );

      expect(
        logs.any((l) =>
            l.startsWith('Warning: config listener failed: Bad state: broken listener')),
        isTrue,
      );
    });

    test('prints warning on config save failure', () {
      final state = AppState();
      state.config.saveOverride = () {
        throw const FileSystemException('disk full');
      };
      final logs = <String>[];

      runZoned(
        () {
          final ok = state.save({'check_interval_minutes': 45});
          expect(ok, isFalse);
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            logs.add(line);
          },
        ),
      );

      expect(
        logs.any((l) => l.startsWith('Warning: could not save config: FileSystemException: disk full')),
        isTrue,
      );
    });
  });
}
