import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/more.dart';
import 'package:app/widgets/overlays.dart';

Finder _sel(String data) => find.byWidgetPredicate(
    (w) => w is SelectableText && w.data == data);

void main() {
  group('overlays', () {
    testWidgets('error dialog shows summary and traceback',
        (t) async {
      SnackLog.clear();
      var closed = false;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ErrorDialog(
        title: 'T',
        summary: 'boom',
        reportText: 'traceback lines',
        onClose: () => closed = true,
      ))));
      expect(_sel('boom'), findsOneWidget);
      expect(_sel('traceback lines'), findsOneWidget);
      expect(find.text(Str.t('error_copy_logs')), findsOneWidget);
      await t.tap(find.text(Str.t('error_close')));
      await t.pump();
      expect(closed, isTrue);
    });

    testWidgets('error dialog with user message hides traceback',
        (t) async {
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: ErrorDialog(
        title: 'T',
        summary: 'boom',
        reportText: 'traceback lines',
        userMessage: 'Zkus to znovu.',
      ))));
      expect(_sel('Zkus to znovu.'), findsOneWidget);
      expect(_sel('traceback lines'), findsNothing);
      expect(find.textContaining('Není to tvoje chyba'),
          findsOneWidget);
    });

    testWidgets('copy button records a copied confirmation',
        (t) async {
      SnackLog.clear();
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: ErrorDialog(
        title: 'T',
        summary: 'boom',
        reportText: 'some report',
      ))));
      await t.tap(find.text(Str.t('error_copy_logs')));
      // The clipboard round-trip is real async work: let it land with
      // the real clock before asserting.
      await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      // Clipboard may fail headless; either confirmation or failure
      // toast is recorded, never a crash.
      expect(SnackLog.last,
          anyOf([Str.t('error_copied'), Str.t('error_copy_failed')]));
    });

    testWidgets('showErrorDialog never throws', (t) async {
      await t.pumpWidget(
          MaterialApp(home: Scaffold(body: Container())));
      final ctx = t.element(find.byType(Scaffold));
      final pending = showErrorDialog(ctx,
          title: 'T', summary: 's', reportText: 'r');
      await t.pump();
      expect(find.byType(ErrorDialog), findsOneWidget);
      Navigator.of(ctx).pop();
      await pending;
    });

    test('snack log records', () {
      SnackLog.clear();
      SnackLog.record('hi');
      expect(SnackLog.last, 'hi');
    });

    test('unknown string falls back to key', () {
      expect(Str.t('no_such_key_xyz'), 'no_such_key_xyz');
    });
  });

  group('more', () {
    testWidgets('entries route to every screen', (t) async {
      SnackLog.clear();
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MorePage(onOpen: opened.add))));
      for (final (route, _, label) in MorePage.entries) {
        await t.tap(find.text(Str.t(label)));
        await t.pump();
        expect(opened, contains(route));
      }
      // Alarm entry only on Android.
      expect(find.text(Str.t('sec_alarm')), findsNothing);
    });

    testWidgets('android inserts the alarm shortcut', (t) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MorePage(
                  onOpen: opened.add, isAndroid: true))));
      expect(find.text(Str.t('sec_alarm')), findsOneWidget);
      await t.tap(find.text(Str.t('sec_alarm')));
      await t.pump();
      expect(opened, contains('alarm'));
    });
  });
}
