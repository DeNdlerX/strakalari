import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/controllers/app_state.dart';
import 'package:app/features/lunches/lunches_controller.dart';
import 'package:app/features/lunches/lunches_format.dart';

AppState _appState() {
  final s = AppState();
  s.demoMode = false;
  s.data = {'absence': {'x': 1}};
  return s;
}

LunchController _controller({bool open = true}) {
  final c = LunchController(
    {},
    isOrderOpen: (_) => open,
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
      expect(core.prefsBanKeywords('nemám rád vepřové'), ['vepřové']);
    });
    test('likes clause ignored', () {
      expect(core.prefsBanKeywords('mám rád kuřecí'), isEmpty);
      expect(core.prefsBanKeywords('preferuji lehká jídla'), isEmpty);
    });
    test('mixed text keeps only dislikes', () {
      expect(core.prefsBanKeywords('nemám rád vepřové, preferuji lehká jídla'),
          ['vepřové']);
    });
    test('bez form', () {
      expect(core.prefsBanKeywords('bez hub a česneku'), ['hub', 'česneku']);
    });
    test('conjunction like segment ignored', () {
      expect(core.prefsBanKeywords('nemám rád vepřové a mám rád kuřecí'),
          ['vepřové']);
      expect(core.prefsBanKeywords('mám rád kuřecí a nemám rád vepřové'),
          ['vepřové']);
    });
    test('english no form', () {
      expect(core.prefsBanKeywords('no pork'), ['pork']);
    });
    test('empty', () {
      expect(core.prefsBanKeywords(''), isEmpty);
      expect(core.prefsBanKeywords(null), isEmpty);
    });
  });

  group('lunches_apply_food_filter (AppState)', () {
    test('prefs hide and stage', () {
      final s = _appState();
      final future = _future();
      s.data = {'absence': {'x': 1}, 'food': _food(future)};
      s.applyFoodFilter('nemám rád vepřové, preferuji lehká jídla');
      expect(s.lunchHidden, {'jidlo&1&x'});
      expect(s.orders[future], 'jidlo&2&x');
      expect(s.pendingOrders, contains(future));
    });

    test('good pick not clobbered', () {
      final s = _appState();
      final future = _future();
      s.data = {'absence': {'x': 1}, 'food': _food(future)};
      s.orders.clear();
      s.orders[future] = 'jidlo&2&x';
      s.applyFoodFilter('nemám rád vepřové');
      expect(s.orders[future], 'jidlo&2&x');
    });

    test('hidden pick replaced', () {
      final s = _appState();
      final future = _future();
      s.data = {'absence': {'x': 1}, 'food': _food(future)};
      s.orders.clear();
      s.orders[future] = 'jidlo&1&x';
      s.applyFoodFilter('nemám rád vepřové');
      expect(s.orders[future], 'jidlo&2&x');
    });

    test('cancelled day skipped', () {
      final s = _appState();
      final future = _future();
      s.data = {'absence': {'x': 1}, 'food': _food(future)};
      s.cancelledLunches.add(future);
      s.applyFoodFilter('nemám rád vepřové');
      expect(s.lunchHidden, {'jidlo&1&x'});
      expect(s.orders.containsKey(future), isFalse);
    });

    test('closed day hides but stages nothing on controller', () {
      final c = _controller(open: false);
      final future = _future();
      c.food = _food(future);
      c.applyFoodFilter('nemám rád vepřové');
      expect(c.lunchHidden, {'jidlo&1&x'});
      expect(c.orders, isEmpty);
    });

    test('isFoodBanned stems and multiword rules', () {
      expect(core.isFoodBanned('Vepřového masa', ['vepřové']).$1, isTrue);
      expect(core.isFoodBanned('Rybízový koláč', ['ryb']).$1, isFalse);
      expect(core.isFoodBanned('Kuřecí maso', ['vepřové maso']).$1, isFalse);
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
