import 'dart:io';

import 'package:app/features/absences/absences_controller.dart';
import 'package:app/features/absences/absences_view.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart' show buildCalendarPresets;
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checkpoint B BR4-S1: a card has the 1 px outline of `components.card`
/// (`border=border_all(1, tok.border)`), and the Absences rows keep the
/// spacing of `views/absences.py` (`tok.gap // 2`, on a phone
/// `tok.gap // 2 + 2`).
void main() {
  final tok = AppTokens.dark();

  void expectOutline(Card card) {
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side.color, tok.border);
    expect(shape.side.width, 1);
    expect(shape.side.style, BorderStyle.solid);
  }

  AbsencesController absences() => AbsencesController()
    ..subjects = const [
      SubjectAbsence(
          name: 'Matematika',
          currentPct: 21.43,
          status: 'warning',
          limitPct: 25,
          effectivePlanLimit: 25,
          effectivePlanSafe: 3),
      SubjectAbsence(
          name: 'Fyzika',
          currentPct: 5,
          status: 'ok',
          limitPct: 25,
          effectivePlanLimit: 25,
          effectivePlanSafe: 5),
    ];

  for (final narrow in [false, true]) {
    testWidgets('absence rows are outlined and spaced (narrow: $narrow)',
        (t) async {
      t.view.physicalSize = Size(narrow ? 390 : 1280, 1200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: tokensFor('dark').toThemeData(),
        home: Scaffold(
          body: AbsencesView(
              controller: absences(), tokens: tok, narrow: narrow),
        ),
      ));
      Finder rowCard(String name) => find.ancestor(
          of: find.text(name), matching: find.byType(Card));
      expectOutline(t.widget<Card>(rowCard('Matematika')));
      expectOutline(t.widget<Card>(rowCard('Fyzika')));
      final gap = t.getRect(rowCard('Fyzika')).top -
          t.getRect(rowCard('Matematika')).bottom;
      expect(gap, (tok.gap ~/ 2) + (narrow ? 2 : 0));
    });
  }

  testWidgets('the wizard card is outlined', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = WizardController(config: {'language': 'cs'}, onSave: (_) => true)
      ..calendarOptions = buildCalendarPresets('cs')
      ..step = WizardController.stepWelcome;
    await t.pumpWidget(MaterialApp(
      theme: tokensFor('dark').toThemeData(),
      home: Scaffold(body: WizardView(controller: c, tokens: tok)),
    ));
    await t.pumpAndSettle();
    expectOutline(t.widget<Card>(find.byType(Card).first));
  });

  test('no feature card replaces the themed shape without an outline', () {
    // A `Card(color: t.card, shape: RoundedRectangleBorder(borderRadius: …))`
    // with no `side:` drops the theme's outline.
    final bare = RegExp(
        r'Card\(\s*color: t\.card,\s*(?://[^\n]*\s*)*shape: RoundedRectangleBorder\(\s*'
        r'borderRadius: BorderRadius\.circular\([^)]*\)\s*\)');
    final offenders = <String>[];
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (bare.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path.replaceAll(r'\', '/'));
      }
    }
    expect(offenders, isEmpty);
  });
}
