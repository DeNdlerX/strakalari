import 'package:app/features/absences/absences_controller.dart';
import 'package:app/features/absences/absences_view.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checkpoint B BR3-M2: Absences looks like `views/absences.py`:
/// the percentage right of every bar (`components.meter`, track 140 px),
/// the "updated" line under the title and stat values coloured by kind.
void main() {
  AbsencesController build() => AbsencesController()
    ..updatedLabel = 'Aktualizováno: dnes'
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

  testWidgets('every row shows its percentage with one decimal',
      (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: AppTokens.dark()))));
    expect(find.text('21.4 %'), findsOneWidget);
    expect(find.text('5.0 %'), findsOneWidget);
    // The track is 140 px wide, like Python.
    final track = t.widgetList<SizedBox>(find.byType(SizedBox)).where(
        (b) => b.width == 140 && b.child is ClipRRect);
    expect(track, hasLength(2));
  });

  testWidgets('the updated line sits under the title', (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: AppTokens.dark()))));
    expect(find.text(Strings.get('absence_title')), findsOneWidget);
    expect(find.text('Aktualizováno: dnes'), findsOneWidget);
  });

  testWidgets('stat values are coloured by kind', (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final tok = AppTokens.dark();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: tok))));
    Color colorOf(String text) =>
        t.widget<Text>(find.text(text).first).style!.color!;
    // One warning subject, none critical: warning colour, then "ok" green.
    expect(colorOf('1'), statusColor('warning', tok));
    expect(colorOf('0'), statusColor('ok', tok));
    // The average is the accent colour (kind "info").
    expect(colorOf('13.2 %'), tok.accent);
  });

  testWidgets('P9a KPI stat cards in row share equal height on 390px phone',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final tok = AppTokens.dark();
    final savedLang = Strings.lang;
    addTearDown(() => Strings.lang = savedLang);
    Strings.lang = 'cs';

    await t.pumpWidget(MaterialApp(
      theme: tok.toThemeData(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: AbsencesView(controller: build(), tokens: tok),
        ),
      ),
    ));
    await t.pump();

    final cards = find.byType(StatCard);
    expect(cards, findsNWidgets(3));
    final heights = [
      for (var i = 0; i < 3; i++) t.getSize(cards.at(i)).height,
    ];
    expect(heights[0], greaterThan(0));
    expect(heights[1], heights[0]);
    expect(heights[2], heights[0]);
  });
}
