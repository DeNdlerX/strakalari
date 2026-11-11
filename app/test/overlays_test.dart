import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/more.dart';
import 'package:app/widgets/app_widgets.dart' show dialogWidth;
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
      expect(find.text(Strings.get('error_copy_logs')), findsOneWidget);
      await t.tap(find.text(Strings.get('error_close')));
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
      expect(find.text(Strings.get('error_not_yours')),
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
      await t.tap(find.text(Strings.get('error_copy_logs')));
      // The clipboard round-trip is real async work: let it land with
      // the real clock before asserting.
      await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      // Clipboard may fail headless; either confirmation or failure
      // toast is recorded, never a crash.
      expect(SnackLog.last,
          anyOf([Strings.get('error_copied'), Strings.get('error_copy_failed')]));
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

    // Checkpoint B B-M14: components.dialog_width(page, 560) on a phone.
    testWidgets('error dialog is 326 px wide on a 390 px page', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ErrorDialog(title: 'T', summary: 's', reportText: 'r'))));
      final box = t.widget<SizedBox>(find
          .descendant(
              of: find.byType(AlertDialog),
              matching: find.byWidgetPredicate(
                  (w) => w is SizedBox && w.width == 326))
          .first);
      expect(box.width, 326);
    });

    // components.dialog_width: int(max(240, min(preferred, width - 64))).
    testWidgets('dialogWidth clamps like Python', (t) async {
      late double got;
      Future<void> at(double w, double preferred) async {
        t.view.physicalSize = Size(w, 800);
        t.view.devicePixelRatio = 1.0;
        await t.pumpWidget(MaterialApp(
            home: Builder(builder: (context) {
          got = dialogWidth(context, preferred);
          return const SizedBox();
        })));
      }

      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await at(390, 560);
      expect(got, 326);
      await at(1280, 520);
      expect(got, 520);
      await at(200, 440);
      expect(got, 240);
      await at(390, 380);
      expect(got, 326);
    });

    test('snack log records', () {
      SnackLog.clear();
      SnackLog.record('hi');
      expect(SnackLog.last, 'hi');
    });

    test('unknown string falls back to key', () {
      expect(Strings.get('no_such_key_xyz'), 'no_such_key_xyz');
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
        await t.tap(find.text(Strings.get(label)));
        await t.pump();
        expect(opened, contains(route));
      }
      // Alarm entry only on Android.
      expect(find.text(Strings.get('sec_alarm')), findsNothing);
    });

    testWidgets('android inserts the alarm shortcut', (t) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MorePage(
                  onOpen: opened.add, isAndroid: true))));
      expect(find.text(Strings.get('sec_alarm')), findsOneWidget);
      await t.tap(find.text(Strings.get('sec_alarm')));
      await t.pump();
      expect(opened, contains('alarm'));
    });
  });
}
