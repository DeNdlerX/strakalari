// Parity tests for MorePage and openMoreRoute (port of views/more.py,
// Checkpoint B B-M10).

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/more.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MorePage Entries & Routing', () {
    test('desktopOrNonAndroidHasFourEntries', () {
      final page = MorePage(onOpen: (_) {}, isAndroid: false);
      final items = page.visibleEntries();
      expect(items.length, 4);
      expect(items.map((e) => e.$1).toList(), [
        'absences',
        'planner',
        'activity',
        'settings',
      ]);
    });

    test('androidInsertsAlarmEntryBeforeSettings', () {
      final page = MorePage(onOpen: (_) {}, isAndroid: true);
      final items = page.visibleEntries();
      expect(items.length, 5);
      expect(items.map((e) => e.$1).toList(), [
        'absences',
        'planner',
        'activity',
        'alarm',
        'settings',
      ]);
      expect(items[3].$1, 'alarm');
      expect(items[3].$2, Icons.alarm);
      expect(items[3].$3, 'sec_alarm');
    });

    test('openMoreRouteAlarmOpensSettingsInAlarmSection', () {
      final state = AppState();
      state.settingsOpen = false;
      state.settingsSection = 'accounts';

      String? target;
      openMoreRoute(state, 'alarm', (route) => target = route);

      expect(target, 'settings');
      expect(state.settingsSection, 'alarm');
      expect(state.settingsOpen, isTrue);
    });

    test('openMoreRouteSettingsOpensSettingsOnList', () {
      final state = AppState();
      state.settingsOpen = true;

      String? target;
      openMoreRoute(state, 'settings', (route) => target = route);

      expect(target, 'settings');
      expect(state.settingsOpen, isFalse);
    });

    test('openMoreRouteStandardScreenNavigatesDirectly', () {
      final state = AppState();

      String? target;
      openMoreRoute(state, 'planner', (route) => target = route);

      expect(target, 'planner');
    });
  });

  group('MorePage Widget', () {
    testWidgets('rendersTitleAndStyledTiles', (tester) async {
      final tokens = AppTokens.dark();
      final opened = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MorePage(
              tokens: tokens,
              isAndroid: true,
              onOpen: opened.add,
            ),
          ),
        ),
      );

      expect(find.text(Strings.get('nav_more')), findsOneWidget);
      expect(find.text(Strings.get('sec_alarm')), findsOneWidget);
      expect(find.text(Strings.get('nav_settings')), findsOneWidget);

      // Tap alarm
      await tester.tap(find.text(Strings.get('sec_alarm')));
      await tester.pumpAndSettle();
      expect(opened, ['alarm']);
    });
  });
}
