// Port of TestSettings (tests/test_status_notification.py): the phone's
// Settings → Background lists every notification line with a switch and
// a preview, and a switch saves quietly and updates the preview in place.
// Also the Store build's startup card (settings/automation.py `_browser`).
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

void main() {
  setUp(() => Strings.lang = 'cs');

  (SettingsController, List<Map<String, dynamic>>, List<int>) phone() {
    final config = <String, dynamic>{'run_in_background': true, 'check_interval_minutes': 30};
    final saved = <Map<String, dynamic>>[];
    final c = SettingsController(config, persistQuiet: (u) {
      saved.add(Map.of(u));
      return true;
    }, isAndroid: true);
    c.backgroundStatusInputs =
        () => core.StatusInputs(config: Map<String, Object?>.of(c.config), pendingExcuses: 1);
    final renders = <int>[];
    c.addListener(() => renders.add(1));
    return (c, saved, renders);
  }

  Future<void> open(WidgetTester t, SettingsController c) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    c.settingsSection = 'browser';
    c.settingsOpen = true;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SettingsView(controller: c, narrow: true, platform: 'android'))));
  }

  String preview(WidgetTester t) => t
      .widgetList<Text>(find.descendant(of: find.byKey(const Key('bg:preview')), matching: find.byType(Text)))
      .map((w) => w.data ?? '')
      .join('\n');

  testWidgets('backgroundSectionListsTheLinesAndAPreview', (t) async {
    final (c, _, _) = phone();
    await open(t, c);
    for (final item in core.items) {
      expect(find.text(Strings.get('bg_item_$item')), findsOneWidget, reason: item);
    }
    expect(find.text(Strings.get('bg_preview')), findsOneWidget);
    expect(preview(t), contains('Omluvenky k odeslání: 1'));
  });

  testWidgets('aSwitchSavesAndUpdatesThePreviewInPlace', (t) async {
    final (c, saved, renders) = phone();
    await open(t, c);
    final tile = find.byKey(const Key('bg:item:excuses'));
    expect(t.widget<SwitchListTile>(tile).value, isTrue);
    expect(preview(t), contains('Omluvenky k odeslání: 1'));
    await t.tap(tile);
    await t.pump();
    expect(c.get('background_notification_items'),
        [for (final i in core.defaultItems) if (i != 'excuses') i]);
    expect(preview(t), isNot(contains('Omluvenky k odeslání: 1')));
    expect(renders, isEmpty); // in place, no page render
    expect(saved.last['background_notification_items'], isNot(contains('excuses')));
    expect(t.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets('restrictedBatteryUseIsFlaggedWithAWayToTheSettings', (t) async {
    final (c, _, _) = phone();
    var opened = 0;
    c.openBatterySettings = () => opened++;
    final warning = find.text(Strings.get('run_in_background_battery'));

    await open(t, c); // unrestricted: nothing to say
    expect(warning, findsNothing);

    c.batteryUnrestricted = false;
    await open(t, c);
    expect(warning, findsOneWidget);
    await t.tap(find.byKey(const Key('bg:battery')));
    expect(opened, 1);

    c.config['run_in_background'] = false; // not running: no matter
    await open(t, c);
    expect(warning, findsNothing);
  });

  testWidgets('storeBuildOffersTheStartupSettingsAndKeepsTheTraySwitch', (t) async {
    final c = SettingsController({'minimize_to_tray': true}, storeManaged: true);
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    c.settingsSection = 'browser';
    c.settingsOpen = true;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(controller: c, narrow: true))));
    expect(find.text(Strings.get('autostart_store_managed')), findsOneWidget);
    expect(find.byKey(const Key('browser:startup-settings')), findsOneWidget);
    expect(find.text(Strings.get('minimize_to_tray')), findsOneWidget);
    expect(find.text(Strings.get('autostart')), findsNothing);
  });
}
