import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/lunches/lunch_filter.dart';
import 'package:app/features/lunches/lunches_controller.dart';

LunchController _controller() {
  final c = LunchController(
    {},
    isOrderOpen: (_) => true,
    readBlacklist: () => [],
  );
  c.stravaOn = true;
  return c;
}

Map<String, Map<String, String>> _food(String day) => {
      day: {
        'jidlo&1&x': 'Vepřové maso na paprice',
        'jidlo&2&x': 'Kuřecí prsa s rýží',
      },
    };

String _future() {
  final d = DateTime.now().add(const Duration(days: 7));
  return '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';
}

void main() {
  group('lunches_prefs_keywords', () {
    test('negation clause yields keyword', () {
      expect(prefsBanKeywords('nemám rád vepřové'), ['vepřové']);
    });
    test('likes clause ignored', () {
      expect(prefsBanKeywords('mám rád kuřecí'), isEmpty);
      expect(prefsBanKeywords('preferuji lehká jídla'), isEmpty);
    });
    test('mixed text keeps only dislikes', () {
      expect(prefsBanKeywords('nemám rád vepřové, preferuji lehká jídla'),
          ['vepřové']);
    });
    test('bez form', () {
      expect(prefsBanKeywords('bez hub a česneku'), ['hub', 'česneku']);
    });
    test('conjunction like segment ignored', () {
      expect(prefsBanKeywords('nemám rád vepřové a mám rád kuřecí'),
          ['vepřové']);
      expect(prefsBanKeywords('mám rád kuřecí a nemám rád vepřové'),
          ['vepřové']);
    });
    test('english no form', () {
      expect(prefsBanKeywords('no pork'), ['pork']);
    });
    test('empty', () {
      expect(prefsBanKeywords(''), isEmpty);
      expect(prefsBanKeywords(null), isEmpty);
    });
  });

  group('lunches_apply_food_filter', () {
    test('prefs hide and stage', () {
      final c = _controller();
      final future = _future();
      c.food = _food(future);
      c.applyFoodFilter('nemám rád vepřové, preferuji lehká jídla');
      expect(c.lunchHidden, {'jidlo&1&x'});
      expect(c.orders[future], 'jidlo&2&x');
      expect(c.pendingOrders, contains(future));
    });

    test('good pick not clobbered', () {
      final c = _controller();
      final future = _future();
      c.food = _food(future);
      c.orders = {future: 'jidlo&2&x'};
      c.applyFoodFilter('nemám rád vepřové');
      expect(c.orders[future], 'jidlo&2&x');
    });

    test('hidden pick replaced', () {
      final c = _controller();
      final future = _future();
      c.food = _food(future);
      c.orders = {future: 'jidlo&1&x'};
      c.applyFoodFilter('nemám rád vepřové');
      expect(c.orders[future], 'jidlo&2&x');
    });

    test('cancelled day skipped', () {
      final c = _controller();
      final future = _future();
      c.food = _food(future);
      c.cancelledLunches.add(future);
      c.applyFoodFilter('nemám rád vepřové');
      expect(c.lunchHidden, {'jidlo&1&x'});
      expect(c.orders.containsKey(future), isFalse);
    });

    test('closed day hides but stages nothing', () {
      final c = LunchController(
        {},
        isOrderOpen: (_) => false,
        readBlacklist: () => [],
      )..stravaOn = true;
      final future = _future();
      c.food = _food(future);
      c.applyFoodFilter('nemám rád vepřové');
      expect(c.lunchHidden, {'jidlo&1&x'});
      expect(c.orders, isEmpty);
    });

    test('isFoodBanned stems and multiword rules', () {
      expect(isFoodBanned('Vepřového masa', ['vepřové']).$1, isTrue);
      expect(isFoodBanned('Rybízový koláč', ['ryb']).$1, isFalse);
      expect(isFoodBanned('Kuřecí maso', ['vepřové maso']).$1, isFalse);
    });
  });

  group('lunches_meal_split', () {
    test('split meal', () {
      expect(splitMeal('Kulajda; Pečené kuře, rýže (1,7,9)'),
          ('Kulajda', 'Pečené kuře, rýže', '1, 7, 9'));
      expect(splitMeal('Rizoto se sýrem,okurka(1a, 7)'),
          ('', 'Rizoto se sýrem, okurka', '1a, 7'));
      // Parentheses that are not allergen codes stay in the name.
      expect(splitMeal('Buchty (sladké)'), ('', 'Buchty (sladké)', ''));
    });

    test('shared soup', () {
      expect(
          sharedSoup({'1': 'Kulajda; A (1)', '2': 'Kulajda; B (7)'}),
          'Kulajda');
      expect(sharedSoup({'1': 'A; X', '2': 'B; Y'}), '');
    });
  });
}
