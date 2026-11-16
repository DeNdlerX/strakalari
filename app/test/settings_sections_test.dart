import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

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
  // Sections are taller than the default 800x600 test surface (the lazy
  // list would not build, or reach, their lower fields).
  t.view.physicalSize = const Size(800, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
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

      for (final answer in ['cancel', 'dry_run']) {
        testWidgets('mode picker shows the saved mode after "$answer"',
            (t) async {
          final c = SettingsController(
            {'excuse_mode': 'confirm'},
            confirmAutoMode: (_) => answer,
          );
          c.settingsSection = 'rules';
          c.settingsOpen = true;
          SnackLog.clear();
          // Like the live screen: every change rebuilds the view.
          await t.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: StatefulBuilder(
                      builder: (context, setState) => SettingsView(
                          controller: c,
                          narrow: true,
                          onChanged: () => setState(() {}))))));
          final dd = find.byKey(const Key('rule:excuse_mode'));
          await t.tap(dd);
          await t.pumpAndSettle();
          await t.tap(find.text(Strings.get('mode_auto')).last);
          await t.pumpAndSettle();
          final shown = answer == 'cancel' ? 'mode_confirm' : 'mode_dry_run';
          expect(
              find.descendant(
                  of: dd, matching: find.text(Strings.get(shown))),
              findsOneWidget);
          expect(
              find.descendant(
                  of: dd, matching: find.text(Strings.get('mode_auto'))),
              findsNothing);
        });
      }

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

  group('B5 school calendar presets', () {
    testWidgets(
        'preset dropdown lists all core presets plus custom and selects saved school_preset_id',
        (t) async {
      Strings.lang = 'cs';
      final options = core.presetOptions('cs');
      expect(options, isNotEmpty);
      final targetPreset = options.first;
      final c = _controller({'school_preset_id': targetPreset.$1});

      await _openSection(t, c, 'calendar');

      final dropdown = t.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>).first);
      expect(dropdown.initialValue, targetPreset.$1);

      await t.tap(find.byType(DropdownButtonFormField<String>).first);
      await t.pumpAndSettle();

      for (final (_, title) in options) {
        expect(find.text(title), findsAtLeastNWidgets(1));
      }
      expect(find.text(Strings.get('cal_custom_opt')), findsOneWidget);
    });

    testWidgets(
        'known preset populates empty semester fields from presetCloses without writing config on blur',
        (t) async {
      Strings.lang = 'cs';
      final withCloses = core
          .presetOptions('cs')
          .firstWhere((e) => core.presetCloses(e.$1).$1.isNotEmpty);
      final (expectedSem1, expectedSem2) = core.presetCloses(withCloses.$1);
      expect(expectedSem2, isNotEmpty);

      final cfg = <String, dynamic>{
        'school_preset_id': withCloses.$1,
        'user_free_days': <Object>[],
      };
      final c = SettingsController(cfg);
      await _openSection(t, c, 'calendar');

      final sem1Field =
          t.widget<TextField>(find.byKey(const Key('auto:cal:sem1')));
      final sem2Field =
          t.widget<TextField>(find.byKey(const Key('auto:cal:sem2')));
      expect(sem1Field.controller?.text, expectedSem1);
      expect(sem2Field.controller?.text, expectedSem2);

      // Focusing and unfocusing without editing must not write config overrides.
      await t.tap(find.byKey(const Key('auto:cal:sem1')));
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await t.tap(find.byKey(const Key('auto:cal:sem2')));
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();

      expect(cfg.containsKey('sem1_close'), isFalse);
      expect(cfg.containsKey('sem2_close'), isFalse);
    });

    testWidgets(
        'changing preset updates semester defaults when no override exists and empty hints are omitted',
        (t) async {
      Strings.lang = 'cs';
      final options = core.presetOptions('cs');
      final withCloses =
          options.firstWhere((e) => core.presetCloses(e.$1).$1.isNotEmpty);
      final (expectedSem1, expectedSem2) = core.presetCloses(withCloses.$1);

      final c = _controller({'school_preset_id': 'custom'});
      t.view.physicalSize = const Size(800, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      c.settingsSection = 'calendar';
      c.settingsOpen = true;

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsView(
                controller: c,
                narrow: true,
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ),
      );
      await t.pump();

      // Custom preset has no close dates, so hintText must be null rather than duplicating label.
      final initialSem1 =
          t.widget<TextField>(find.byKey(const Key('auto:cal:sem1')));
      expect(initialSem1.decoration?.hintText, isNull);
      final addDateField =
          t.widget<TextField>(find.byKey(const Key('auto:cal:add_date')));
      expect(addDateField.decoration?.hintText, isNull);

      await t.tap(find.byType(DropdownButtonFormField<String>).first);
      await t.pumpAndSettle();
      await t.tap(find.text(withCloses.$2).last);
      await t.pumpAndSettle();

      expect(c.get('school_preset_id'), withCloses.$1);
      final updatedSem1 =
          t.widget<TextField>(find.byKey(const Key('auto:cal:sem1')));
      final updatedSem2 =
          t.widget<TextField>(find.byKey(const Key('auto:cal:sem2')));
      expect(updatedSem1.controller?.text, expectedSem1);
      expect(updatedSem2.controller?.text, expectedSem2);
    });
  });

  group('B6 notification event labels', () {
    testWidgets(
        'every notification event renders its localized cs and en label without raw keys',
        (t) async {
      final prevLang = Strings.lang;
      addTearDown(() => Strings.lang = prevLang);

      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        final c = _controller();
        await _openSection(t, c, 'notifications');

        for (final event in kNotificationEvents) {
          final label = Strings.get('notif_$event');
          expect(label, isNotEmpty);
          expect(label, isNot('notif_$event'));
          expect(label, isNot(event));
          expect(find.text(label), findsOneWidget);
          expect(find.text(event), findsNothing);
        }
      }
    });
  });

  group('B9 background switch rebuilds', () {
    testWidgets('tapping run_in_background updates switch state immediately',
        (t) async {
      Strings.lang = 'cs';
      t.view.physicalSize = const Size(800, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final c = _controller({'run_in_background': true});
      c.settingsSection = 'browser';
      c.settingsOpen = true;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsView(
                controller: c,
                narrow: true,
                platform: 'android',
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ),
      );
      await t.pump();

      final switchFinder = find.widgetWithText(
        SwitchListTile,
        Strings.get('run_in_background'),
      );
      expect(switchFinder, findsOneWidget);
      expect(t.widget<SwitchListTile>(switchFinder).value, isTrue);

      await t.tap(switchFinder);
      await t.pump();
      expect(c.get('run_in_background'), isFalse);
      expect(t.widget<SwitchListTile>(switchFinder).value, isFalse);

      await t.tap(switchFinder);
      await t.pump();
      expect(c.get('run_in_background'), isTrue);
      expect(t.widget<SwitchListTile>(switchFinder).value, isTrue);
    });
  });
}
