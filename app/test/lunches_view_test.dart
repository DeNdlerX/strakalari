import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/lunches/lunches_controller.dart';
import 'package:app/features/lunches/lunches_view.dart';
import 'package:app/widgets/overlays.dart';

String _day(int offset) {
  final d = DateTime.now().add(Duration(days: offset));
  return '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';
}

LunchController _controller() {
  final c = LunchController({}, readBlacklist: () => []);
  c.stravaOn = true;
  c.isOrderOpen = (_) => true;
  return c;
}

Widget _app(Widget child) {
  SnackLog.clear();
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('lunches_view', () {
    testWidgets('strava off shows accounts card', (t) async {
      final c = LunchController({})..stravaOn = false;
      var opened = false;
      await t.pumpWidget(_app(LunchesView(
        controller: c,
        onOpenSettings: () => opened = true,
      )));
      expect(find.text(Strings.get('strava_disabled_title')), findsOneWidget);
      await t.tap(find.text(Strings.get('go_to_settings')));
      expect(opened, isTrue);
    });

    testWidgets('menu hides past days until asked', (t) async {
      final c = _controller();
      final past = _day(-7);
      final future = _day(7);
      c.food = {
        past: {'p1': 'Staré jídlo (1)'},
        future: {'f1': 'Nové jídlo (1)'},
      };
      await t.pumpWidget(_app(LunchesView(controller: c)));
      expect(find.textContaining('Nové jídlo'), findsOneWidget);
      expect(find.textContaining('Staré jídlo'), findsNothing);
      expect(
          find.text(Strings.format('lunch_show_past', {'n': 1})), findsOneWidget);
      await t.tap(find.text(Strings.format('lunch_show_past', {'n': 1})));
      await t.pump();
      expect(c.showPastLunches, isTrue);
    });

    testWidgets('empty menu explains why, per strava status',
        (t) async {
      for (final (status, key) in [
        ('empty', 'lunch_empty_no_menu'),
        ('no_login', 'lunch_empty_no_login'),
        (null, 'need_credentials'),
      ]) {
        final c = _controller()
          ..food = {}
          ..config['strava_status'] = status;
        await t.pumpWidget(_app(LunchesView(controller: c)));
        expect(find.text(Strings.get('no_data')), findsOneWidget);
        expect(find.text(Strings.get(key)), findsOneWidget);
      }
    });

    testWidgets('picking a meal stages it; send shows pending count',
        (t) async {
      final c = _controller();
      final future = _day(7);
      c.food = {
        future: {
          'jidlo&1&x': 'Vepřové (1)',
          'jidlo&2&x': 'Kuřecí (7)',
        },
      };
      await t.pumpWidget(_app(LunchesView(controller: c)));
      await t.tap(find.textContaining('Kuřecí').first);
      await t.pump();
      expect(c.orders[future], 'jidlo&2&x');
      expect(c.pendingLunchCount, 1);
      // Shell rebuilds on notify; tests re-pump explicitly.
      await t.pumpWidget(_app(LunchesView(controller: c)));
      expect(find.text('${Strings.get('send_orders')} (1)'), findsOneWidget);
      // Day badge says "to send".
      expect(find.text(Strings.get('to_send')), findsWidgets);
    });

    testWidgets('closed day is read-only', (t) async {
      final c = _controller()..isOrderOpen = (_) => false;
      final future = _day(7);
      c.food = {
        future: {'jidlo&1&x': 'Vepřové (1)'},
      };
      await t.pumpWidget(_app(LunchesView(controller: c)));
      expect(
          find.text(Strings.get('lunch_closed_badge')), findsWidgets);
      // Disabled rows are not clickable (like the Flet view): the
      // closed note above them explains why.
      await t.tap(find.textContaining('Vepřové').first,
          warnIfMissed: false);
      await t.pump();
      expect(c.orders.containsKey(future), isFalse);
    });

    testWidgets('web-ordered day shows ordered badge', (t) async {
      final c = _controller();
      final future = _day(7);
      c.food = {
        future: {'jidlo&1&x': 'Vepřové (1)'},
      };
      c.webOrders = {future: 'jidlo&1&x'};
      await t.pumpWidget(_app(LunchesView(controller: c)));
      expect(find.text(Strings.get('web_ordered')), findsOneWidget);
    });

    testWidgets('no-lunch option clears the pick', (t) async {
      final c = _controller();
      final future = _day(7);
      c.food = {
        future: {'jidlo&1&x': 'Vepřové (1)'},
      };
      c.orders = {future: 'jidlo&1&x'};
      c.pendingOrders = {future};
      await t.pumpWidget(_app(LunchesView(controller: c)));
      await t.tap(find.text(Strings.get('no_order_option')));
      await t.pump();
      expect(c.orders.containsKey(future), isFalse);
    });

    test('day status: cancelled / web-ordered / to-send / none', () {
      final c = _controller();
      const day = '07.09.2026';
      final view = LunchesView(controller: c);
      expect(view.dayStatus(day), isNull);
      c.webOrders = {day: 'm1'};
      c.orders = {day: 'm1'};
      expect(view.dayStatus(day), Strings.get('web_ordered'));
      c.orders = {day: 'm2'};
      c.pendingOrders = {day};
      expect(view.dayStatus(day), Strings.get('to_send'));
      c.cancelledLunches.add(day);
      expect(view.dayStatus(day), Strings.get('no_lunch'));
    });

    test('order past cutoff stages nothing', () {
      final c = _controller()..isOrderOpen = (_) => false;
      var logged = 0;
      c.onLog = (_) => logged++;
      expect(c.orderLunch('07.09.2026', 'abc'), isFalse);
      expect(logged, 1);
      expect(c.orders.containsKey('07.09.2026'), isFalse);
    });
  });
}
