import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/l10n/strings.dart';
import 'package:app/widgets/safety_dialog.dart';

Widget _dialogApp({
  required String modeKey,
  required VoidCallback onConfirm,
  required VoidCallback onDryRun,
  required VoidCallback onCancel,
  bool unsigned = false,
  bool? hasDryRunOverride,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => confirmAutoMode(
            context,
            modeKey,
            onConfirm: onConfirm,
            onDryRun: onDryRun,
            onCancel: onCancel,
            unsigned: unsigned,
            hasDryRunOverride: hasDryRunOverride,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    // Ensure audit file does not leak across tests
    try {
      final f = File(core.historyPath());
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  });

  tearDown(() {
    try {
      final f = File(core.historyPath());
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  });

  group('test_automation_safety confirm_auto_mode', () {
    testWidgets('test_auto_confirm_dialog_recommends_dry_run_first', (t) async {
      final picked = <String>[];
      await t.pumpWidget(_dialogApp(
        modeKey: 'excuse_mode',
        onConfirm: () => picked.add('auto'),
        onDryRun: () => picked.add('dry'),
        onCancel: () => picked.add('cancel'),
      ));

      // Open dialog
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      // Dialog title and warning about no dry run
      expect(find.text(Strings.get('auto_confirm_title')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_no_dry_run')), findsOneWidget);

      // Tap "Nejdříve nanečisto" (action 1 in Python)
      await t.tap(find.text(Strings.get('auto_confirm_dry')));
      await t.pumpAndSettle();

      // Only 'dry' was picked, closing afterwards does not also cancel
      expect(picked, ['dry']);
      expect(find.text(Strings.get('auto_confirm_title')), findsNothing);
    });

    testWidgets('test_auto_confirm_dialog_after_dry_run', (t) async {
      core.record('lunch', 'dry_run', 'manual', 'x');

      final picked = <String>[];
      await t.pumpWidget(_dialogApp(
        modeKey: 'strava_order_mode',
        onConfirm: () => picked.add('auto'),
        onDryRun: () => picked.add('dry'),
        onCancel: () => picked.add('cancel'),
      ));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      // Because dry run exists, recommendation is absent
      expect(find.text(Strings.get('auto_confirm_no_dry_run')), findsNothing);

      // Tap "Ano, zapnout" (action 2 in Python)
      await t.tap(find.text(Strings.get('auto_confirm_ok')));
      await t.pumpAndSettle();

      expect(picked, ['auto']);
    });

    testWidgets('test_auto_confirm_dialog_warns_unsigned_excuses', (t) async {
      // 1. excuse_mode, unsigned = true -> warning present
      await t.pumpWidget(_dialogApp(
        modeKey: 'excuse_mode',
        unsigned: true,
        onConfirm: () {},
        onDryRun: () {},
        onCancel: () {},
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text(Strings.get('auto_confirm_unsigned')), findsOneWidget);
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      // 2. excuse_mode, unsigned = false -> warning absent
      await t.pumpWidget(_dialogApp(
        modeKey: 'excuse_mode',
        unsigned: false,
        onConfirm: () {},
        onDryRun: () {},
        onCancel: () {},
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text(Strings.get('auto_confirm_unsigned')), findsNothing);
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      // 3. strava_order_mode, unsigned = true -> warning absent (lunch orders carry no signature)
      await t.pumpWidget(_dialogApp(
        modeKey: 'strava_order_mode',
        unsigned: true,
        onConfirm: () {},
        onDryRun: () {},
        onCancel: () {},
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text(Strings.get('auto_confirm_unsigned')), findsNothing);
    });

    testWidgets('dialog dismissal triggers onCancel once', (t) async {
      final picked = <String>[];
      await t.pumpWidget(_dialogApp(
        modeKey: 'excuse_mode',
        onConfirm: () => picked.add('auto'),
        onDryRun: () => picked.add('dry'),
        onCancel: () => picked.add('cancel'),
      ));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      // Tap cancel
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      expect(picked, ['cancel']);
    });
  });
}
