// The phone's morning brief: its card in Settings → Notifications (the
// switch, the time, the lines and a preview that follows them in place) and
// the queue AppState hands to the phone.
import 'dart:convert';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/format.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

const _noHolidays = {
  'school_preset_id': 'custom',
  'user_free_days': <Object?>[],
  'holidays': <Object?>[],
};

/// A lesson at 8:00 on each of the next three weeks' days (from the real
/// "now": the card asks the clock).
Map<String, Object?> _timetable() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return {
    for (var i = 0; i < 21; i++)
      dayKey(DateTime(today.year, today.month, today.day + i)): [
        {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika', 'room': '214'},
      ],
  };
}

class _Bridge implements core.MorningBriefPhoneBridge {
  final List<String> queues = [];

  @override
  bool setMorningBriefs(String queueJson, String channelName) {
    queues.add(queueJson);
    return true;
  }
}

void main() {
  setUp(() => Strings.lang = 'cs');

  (SettingsController, List<Map<String, dynamic>>, List<int>) phone(
      [Map<String, dynamic> extra = const {}]) {
    final config = <String, dynamic>{..._noHolidays, ...extra};
    final saved = <Map<String, dynamic>>[];
    final c = SettingsController(config, persistQuiet: (u) {
      saved.add(Map.of(u));
      return true;
    }, isAndroid: true);
    c.backgroundStatusInputs = () => core.StatusInputs(
          timetable: _timetable(),
          config: Map<String, Object?>.of(c.config),
          pendingExcuses: 2,
          freeDays: {},
        );
    final renders = <int>[];
    c.addListener(() => renders.add(1));
    return (c, saved, renders);
  }

  Future<void> open(WidgetTester t, SettingsController c,
      {String platform = 'android'}) async {
    t.view.physicalSize = const Size(800, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    c.settingsSection = 'notifications';
    c.settingsOpen = true;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SettingsView(controller: c, narrow: true, platform: platform))));
  }

  String preview(WidgetTester t) => t
      .widgetList<Text>(find.descendant(
          of: find.byKey(const Key('brief:preview')), matching: find.byType(Text)))
      .map((w) => w.data ?? '')
      .join('\n');

  testWidgets('onlyThePhoneOffersTheBrief', (t) async {
    final (c, _, _) = phone();
    await open(t, c, platform: 'windows');
    expect(find.byKey(const Key('brief:enabled')), findsNothing);
    await open(t, c);
    expect(find.byKey(const Key('brief:enabled')), findsOneWidget);
    // Off: only the switch.
    expect(find.byKey(const Key('brief:time')), findsNothing);
    expect(find.byKey(const Key('brief:preview')), findsNothing);
  });

  testWidgets('switchingItOnSavesAndShowsTheSettingsAndAPreview', (t) async {
    final (c, saved, renders) = phone();
    await open(t, c);
    await t.tap(find.byKey(const Key('brief:enabled')));
    await t.pump();
    expect(saved.last, {'morning_brief_enabled': true});
    expect(renders, isEmpty); // in place, no page render
    expect(find.byKey(const Key('brief:time')), findsOneWidget);
    expect(find.descendant(
            of: find.byKey(const Key('brief:time')), matching: find.text('6:30')),
        findsOneWidget);
    for (final item in core.items) {
      final tile = find.byKey(Key('brief:item:$item'));
      expect(t.widget<SwitchListTile>(tile).value,
          core.defaultBriefItems.contains(item),
          reason: item);
    }
    final text = preview(t);
    expect(text, contains('Příští přehled:'));
    expect(text, contains('v 6:30'));
    expect(text, contains('Ranní přehled'));
    expect(text, contains('Matematika'));
    expect(text, contains('Omluvenky k odeslání: 2'));
  });

  testWidgets('anItemSwitchSavesAndUpdatesThePreviewInPlace', (t) async {
    final (c, saved, renders) = phone({'morning_brief_enabled': true});
    await open(t, c);
    expect(preview(t), contains('Omluvenky k odeslání: 2'));
    await t.tap(find.byKey(const Key('brief:item:excuses')));
    await t.pump();
    expect(saved.last['morning_brief_items'],
        [for (final i in core.defaultBriefItems) if (i != 'excuses') i]);
    expect(preview(t), isNot(contains('Omluvenky k odeslání')));
    expect(renders, isEmpty);
  });

  testWidgets('theTimeComesFromThePicker', (t) async {
    final (c, saved, _) = phone(
        {'morning_brief_enabled': true, 'morning_brief_time': '07:05'});
    await open(t, c);
    expect(find.descendant(
            of: find.byKey(const Key('brief:time')), matching: find.text('7:05')),
        findsOneWidget);
    expect(preview(t), contains('v 7:05'));
    await t.tap(find.byKey(const Key('brief:time')));
    await t.pumpAndSettle();
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(saved.last, {'morning_brief_time': '07:05'});
  });

  test('savingTheBriefSettingsHandsTheQueueToThePhone', () {
    withClock(Clock.fixed(DateTime(2026, 10, 12, 12)), () {
      final bridge = _Bridge();
      core.morningBriefPhoneBridge = bridge;
      core.resetMorningBriefSyncState();
      addTearDown(() {
        core.morningBriefPhoneBridge = null;
        core.resetMorningBriefSyncState();
      });
      final s = AppState(
        configData: {
          ..._noHolidays,
          'morning_brief_items': ['next_lesson'],
        },
        data: {
          'absence': {'Matematika': 1.0},
          'timetable': {
            dayKey(DateTime(2026, 10, 13)): [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
            ],
          },
        },
      );
      s.demoMode = false;
      s.save({'morning_brief_enabled': true});
      final queue = jsonDecode(bridge.queues.last) as List;
      expect((queue.single as Map)['at'],
          DateTime(2026, 10, 13, 6, 30).millisecondsSinceEpoch);
      expect((queue.single as Map)['text'], contains('Matematika'));

      s.save({'morning_brief_time': '07:15'});
      expect((jsonDecode(bridge.queues.last) as List).single['at'],
          DateTime(2026, 10, 13, 7, 15).millisecondsSinceEpoch);

      // Off: an empty queue (the phone cancels what it holds).
      s.save({'morning_brief_enabled': false});
      expect(bridge.queues.last, '[]');
    });
  });
}
