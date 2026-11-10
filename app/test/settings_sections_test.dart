import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/widgets/overlays.dart';

SettingsController _controller([Map<String, dynamic>? config]) {
  return SettingsController(config ??
      {
        'school_preset_id': 'custom',
        'user_free_days': [],
        'gemini_api_key': 'x',
        'absence': {'Matematika': 5.0},
        'subject_limits': <String, double>{},
      });
}

Widget _app(SettingsController c,
    {bool narrow = false, String platform = ''}) {
  SnackLog.clear();
  return MaterialApp(
      home: Scaffold(
          body: SettingsView(
              controller: c, narrow: narrow, platform: platform)));
}

Future<void> _openSection(
    WidgetTester t, SettingsController c, String section,
    {String platform = ''}) async {
  c.settingsSection = section;
  await t.pumpWidget(
      _app(c, narrow: true, platform: platform));
  c.settingsOpen = true;
  await t.pumpWidget(
      _app(c, narrow: true, platform: platform));
}

void main() {
  group('settings_sections', () {
    test('nav groups cover every section', () {
      final grouped = [
        for (final g in SettingsController.navGroups)
          for (final id in g.$2) id,
      ];
      final ids = [
        for (final s in SettingsController.sections) s.$1
      ];
      expect(grouped.toSet(), ids.toSet());
      expect(grouped, hasLength(grouped.toSet().length));
      expect(SettingsController.sectionIcons.keys.toSet(),
          ids.toSet());
    });

    for (final language in ['cs', 'en']) {
      testWidgets('every section builds ($language)', (t) async {
        Strings.lang = language;
        final c = _controller();
        for (final section in SettingsController.sections) {
          await _openSection(t, c, section.$1,
              platform:
                  section.$1 == 'alarm' ? 'android' : '');
          expect(find.byType(SettingsView), findsOneWidget,
              reason: section.$1);
        }
        Strings.lang = 'cs';
      });
    }

    test('sections hidden per platform', () {
      final c = _controller();
      final ids =
          c.sectionsHere().map((s) => s.$1).toSet();
      expect(ids, isNot(contains('alarm')));
      final android =
          c.sectionsHere(platform: 'android').map((s) => s.$1).toSet();
      expect(android, contains('alarm'));
      final ios =
          c.sectionsHere(platform: 'ios').map((s) => s.$1).toSet();
      expect(ios, isNot(contains('browser')));
    });

    group('calendar', () {
      testWidgets('add single day', (t) async {
        final c = _controller();
        await _openSection(t, c, 'calendar');
        final d = DateTime.now().add(const Duration(days: 30));
        final key =
            '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
        await t.enterText(
            find.byKey(const Key('auto:cal:add_date')), key);
        await t.enterText(
            find.byKey(const Key('auto:cal:add_label')), 'Výlet');
        await t.pump();
        await t.tap(find.byKey(const Key('cal:add_single')));
        await t.pump();
        expect(
            (c.get('user_free_days') as List)
                .any((e) => e is Map && e['date'] == key),
            isTrue);
      });

      testWidgets('invalid date saves nothing', (t) async {
        final c = _controller();
        await _openSection(t, c, 'calendar');
        await t.enterText(
            find.byKey(const Key('auto:cal:add_date')), '31.02.2026');
        await t.pump();
        await t.tap(find.byKey(const Key('cal:add_single')));
        await t.pump();
        expect(c.get('user_free_days'), isEmpty);
      });

      testWidgets('add range then delete it', (t) async {
        // Tall viewport: the whole section stays hittable, no scrolling.
        t.view.physicalSize = const Size(800, 2000);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.resetPhysicalSize);
        final c = _controller();
        await _openSection(t, c, 'calendar');
        final start =
            DateTime.now().add(const Duration(days: 40));
        String fmt(DateTime d) =>
            '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
        await t.enterText(
            find.byKey(const Key('auto:cal:from_')), fmt(start));
        await t.enterText(
            find.byKey(const Key('auto:cal:to')),
            fmt(start.add(const Duration(days: 2))));
        await t.enterText(
            find.byKey(const Key('auto:cal:range_label')), 'Prázdniny');
        await t.pump();
        final addRange = find.byKey(const Key('cal:add_range'));
        await t.tap(addRange);
        await t.pump();
        final days = c.userFreeDays();
        expect(days, hasLength(3));
        // Rebuild: the grouped row with one delete button appears.
        await t.pumpWidget(
            _app(c, narrow: true));
        c.settingsSection = 'calendar';
        c.settingsOpen = true;
        await t.pumpWidget(
            _app(c, narrow: true));
        // Delete the grouped row.
        await t.tap(find.byTooltip(Strings.get('delete')).first);
        await t.pump();
        expect(c.userFreeDays(), isEmpty);
      });

      testWidgets('reversed range is rejected', (t) async {
        final c = _controller();
        await _openSection(t, c, 'calendar');
        await t.enterText(
            find.byKey(const Key('auto:cal:from_')), '10.11.2026');
        await t.enterText(
            find.byKey(const Key('auto:cal:to')), '01.11.2026');
        await t.pump();
        await t.tap(find.byKey(const Key('cal:add_range')));
        await t.pump();
        expect(c.get('user_free_days'), isEmpty);
      });

      test('closure date is validated', () {
        final c = _controller();
        expect(c.commitClosure('sem1_close', 'not a date'), isFalse);
        expect(c.get('sem1_close', ''), '');
        expect(c.commitClosure('sem1_close', '25.01.2027'), isTrue);
        expect(c.commitClosure('sem1_close', ''), isTrue);
      });
    });

    group('automation rules', () {
      testWidgets('switching to auto needs confirmation', (t) async {
        var asked = '';
        final c = SettingsController(
          {'excuse_mode': 'confirm'},
          confirmAutoMode: (key) {
            asked = key;
            return 'cancel';
          },
        );
        await _openSection(t, c, 'rules');
        final dd = find.byKey(const Key('rule:excuse_mode'));
        await t.tap(dd);
        await t.pumpAndSettle();
        await t.tap(find.text(Strings.get('mode_auto')).last);
        await t.pumpAndSettle();
        expect(asked, 'excuse_mode');
        expect(c.get('excuse_mode'), 'confirm'); // nothing saved yet
        // Cancel keeps the old value; confirm switches.
        final c2 = SettingsController(
          {'excuse_mode': 'confirm'},
          confirmAutoMode: (_) => 'confirm',
        );
        expect(await c2.commitMode('excuse_mode', 'auto', 'confirm'), 'saved');
        expect(c2.get('excuse_mode'), 'auto');
      });

      test('other modes save without asking', () async {
        var asked = false;
        final c = SettingsController(
          {'strava_order_mode': 'confirm'},
          confirmAutoMode: (_) {
            asked = true;
            return 'cancel';
          },
        );
        expect(
            await c.commitMode('strava_order_mode', 'dry_run', 'confirm'),
            'saved');
        expect(asked, isFalse);
        expect(c.get('strava_order_mode'), 'dry_run');
      });

      testWidgets('pause switch pauses automation', (t) async {
        final c = _controller();
        await _openSection(t, c, 'rules');
        await t.tap(find.byKey(const Key('rule:pause')));
        await t.pump();
        expect(c.automationPaused(), isTrue);
      });

      testWidgets('interval is clamped', (t) async {
        final c = _controller();
        await _openSection(t, c, 'rules');
        for (final (raw, expected) in [('0', 1), ('15', 15), ('2,7', 2)]) {
          await t.enterText(
              find.byKey(const Key('auto:rule:interval')), raw);
          await t.pump();
          // Blur-commit via focus change.
          FocusManager.instance.primaryFocus?.unfocus();
          await t.pump();
          expect(c.get('check_interval_minutes'), expected);
        }
      });

      test('invalid cutoff is not saved', () {
        final c = _controller({'lunch_order_cutoff_time': '12:00'});
        expect(c.commitCutoff('25:99'), isFalse);
        expect(c.get('lunch_order_cutoff_time'), '12:00');
        expect(c.commitCutoff(''), isTrue);
      });
    });

    group('browser', () {
      testWidgets('failed autostart reverts the switch', (t) async {
        final c = SettingsController({},
            autostartEnabled: () => false,
            setAutostart: (_) => false);
        await _openSection(t, c, 'browser');
        await t.tap(find.byKey(const Key('browser:autostart')));
        await t.pumpAndSettle();
        // Rejected: the switch keeps the old state.
        expect(
            t.widget<SwitchListTile>(
                find.byKey(const Key('browser:autostart'))).value,
            isFalse);
        expect(SnackLog.last, Strings.get('autostart_failed'));
      });

      testWidgets('store build points autostart to windows settings',
          (t) async {
        final c = SettingsController({}, storeManaged: true);
        await _openSection(t, c, 'browser');
        expect(
            find.text(Strings.get('autostart_store_managed')), findsOneWidget);
        expect(find.text(Strings.get('autostart_open_settings')),
            findsOneWidget);
        expect(find.text(Strings.get('autostart')), findsNothing);
      });
    });
  });
}
