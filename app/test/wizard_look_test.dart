import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/wizard/wizard_live.dart' show buildCalendarPresets;

/// Checkpoint B BR3-M2: the wizard looks like `views/wizard.py`.
void main() {
  final tokens = AppTokens.dark();

  Future<WizardController> pump(WidgetTester t, {String lang = 'cs'}) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = WizardController(config: {'language': lang}, onSave: (_) => true)
      ..calendarOptions = buildCalendarPresets('cs')
      ..step = WizardController.stepWelcome;
    await t.pumpWidget(MaterialApp(
      theme: tokensFor('dark').toThemeData(),
      home: Scaffold(body: WizardView(controller: c, tokens: tokens)),
    ));
    await t.pumpAndSettle();
    return c;
  }

  testWidgets('the card sits at the top of the page, not centred vertically',
      (t) async {
    await pump(t);
    final card = t.getRect(find.byType(Card).first);
    // Page padding is 24 px; Python starts the card at the top.
    expect(card.top, lessThan(60));
  });

  testWidgets('the chosen language is a filled primary button', (t) async {
    await pump(t);
    final chosen = t.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Čeština'));
    expect(chosen.onPressed, isNotNull);
    final bg = chosen.style!.backgroundColor!.resolve({});
    expect(bg, tokens.accent);
    // The other language is a ghost (outlined) button.
    expect(find.widgetWithText(OutlinedButton, 'English'), findsOneWidget);
  });

  testWidgets('the current step dot is yellow, done ones green, rest faint',
      (t) async {
    final c = await pump(t);
    c.step = WizardController.stepSchool;
    c.notifyListeners();
    await t.pumpAndSettle();
    Color dotColor(Element e) =>
        ((e.widget as Container).decoration! as BoxDecoration).color!;
    final dots = find
        .byWidgetPredicate((x) =>
            x is Container &&
            x.constraints?.maxWidth == 10 &&
            x.decoration is BoxDecoration &&
            (x.decoration! as BoxDecoration).shape == BoxShape.circle)
        .evaluate()
        .map(dotColor)
        .toList();
    expect(dots, isNotEmpty);
    expect(dots.first, tokens.green);
    expect(dots, contains(tokens.yellow));
    expect(dots, isNot(contains(tokens.accent)));
    expect(Strings.get('wiz_next'), isNotEmpty);
  });

  testWidgets('Vítejte shows WelcomeLogo and skips entrance animation when disableAnimations is on',
      (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = WizardController(config: {'language': 'cs'}, onSave: (_) => true)
      ..calendarOptions = buildCalendarPresets('cs')
      ..step = WizardController.stepWelcome;
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(
        theme: tokensFor('dark').toThemeData(),
        home: Scaffold(body: WizardView(controller: c, tokens: tokens)),
      ),
    ));
    // First frame already shows final state without waiting for animation.
    expect(find.byType(WelcomeLogo), findsOneWidget);
    final fades = t.widgetList<FadeTransition>(find.byType(FadeTransition));
    expect(fades.every((f) => f.opacity.value == 1.0), isTrue);
  });
}
