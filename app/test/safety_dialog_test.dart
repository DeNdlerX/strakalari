import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/l10n/strings.dart';
import 'package:app/widgets/safety_dialog.dart';

Widget _dialogApp({
  required String modeKey,
  required VoidCallback onConfirm,
  required VoidCallback onCancel,
  bool unsigned = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => confirmAutoMode(
            context,
            modeKey,
            onConfirm: onConfirm,
            onCancel: onCancel,
            unsigned: unsigned,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  group('test_automation_safety confirm_auto_mode', () {
    testWidgets('excuse dialog explains the risk and confirms once', (t) async {
      final picked = <String>[];
      await t.pumpWidget(_dialogApp(
        modeKey: 'excuse_mode',
        onConfirm: () => picked.add('auto'),
        onCancel: () => picked.add('cancel'),
      ));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text(Strings.get('auto_confirm_title_excuse')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_excuse')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_excuse_risk')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_pause_hint')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_history')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_lunch_risk')), findsNothing);
      // Only Cancel and Turn on.
      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextButton)),
          findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);

      await t.tap(find.text(Strings.get('auto_confirm_ok')));
      await t.pumpAndSettle();

      expect(picked, ['auto']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('lunch dialog shows the lunch wording', (t) async {
      final picked = <String>[];
      await t.pumpWidget(_dialogApp(
        modeKey: 'strava_order_mode',
        onConfirm: () => picked.add('auto'),
        onCancel: () => picked.add('cancel'),
      ));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text(Strings.get('auto_confirm_title_lunch')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_lunch')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_lunch_risk')), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_excuse_risk')), findsNothing);

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
        onCancel: () => picked.add('cancel'),
      ));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      expect(picked, ['cancel']);
    });
  });
}
