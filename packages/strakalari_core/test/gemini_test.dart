// Gemini AI lunch recommendations: key validation, picks, local fallback.
//
// Port of tests/test_gemini_key.py (all cases), tests/test_gemini_picks.py
// (all cases) and tests/test_ai_recommend.py (pure cases). Gemini calls go
// through the injectable [GeminiTransport] seam — no real network in tests.
//
// Cases NOT ported here (their subjects live in other modules):
// - test_worker_reports_closed_days_separately,
//   test_worker_says_closed_when_everything_is_past_cutoff,
//   test_recommend_respects_skip_and_marks_pending,
//   test_recommend_busy_guard_snacks_instead_of_rerunning -> AppState AI
//   worker + Lunches view (phase 5).
import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/lunches/gemini.dart';
import 'package:strakalari_core/src/lunches/lunch_auto.dart';

Map<String, Map<String, String>> get food => {
      '16.09.2026': {'a&1&0': 'Kureci rizek', 'a&2&0': 'Veprova pecene'},
      '17.09.2026': {'b&1&0': 'Rybi file', 'b&2&0': 'Sunkove koleno'},
    };

// Local fallback always takes the first meal of each day (all scores tie).
Map<String, String> get expectedFallback => {
      '16.09.2026': 'a&1&0',
      '17.09.2026': 'b&1&0',
    };

String geminiReply(String text) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text}
            ]
          }
        }
      ]
    });

/// Fake transport answering every call with [script] payloads in order
/// (last one repeats), recording each request.
class FakeGeminiTransport {
  FakeGeminiTransport(this.script);

  final List<GeminiHttpResponse> script;
  final List<({Uri url, Map<String, String> headers, List<int>? body})> calls =
      [];

  Future<GeminiHttpResponse> call(
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    calls.add((url: url, headers: Map.of(headers), body: body));
    final response = calls.length <= script.length
        ? script[calls.length - 1]
        : script.last;
    return response;
  }
}

GeminiHttpResponse jsonReply(String text, {int status = 200}) =>
    GeminiHttpResponse(status, utf8.encode(geminiReply(text)));

void main() {
  group('api key', () {
    test('success', () async {
      final fake = FakeGeminiTransport([
        GeminiHttpResponse(200, utf8.encode('{"displayName": "Gemini Flash"}')),
      ]);
      final (ok, message) = await testApiKey(
        'AIza-secret',
        model: 'gemini-3.8-flash',
        transport: fake.call,
      );
      expect(ok, isTrue);
      expect(message, contains('Gemini Flash'));
      expect(message, isNot(contains('AIza-secret')));
    });

    test('empty', () async {
      final (ok, message) = await testApiKey('');
      expect(ok, isFalse);
      expect(message, isNotEmpty);
    });

    test('invalid key', () async {
      final fake = FakeGeminiTransport([
        GeminiHttpResponse(
            400, utf8.encode('{"error": {"message": "API key not valid."}}')),
      ]);
      final (ok, message) = await testApiKey(
        'AIza-wrong',
        transport: fake.call,
      );
      expect(ok, isFalse);
      expect(message, contains('Neplatný'));
      expect(message, isNot(contains('AIza-wrong')));
    });

    test('bad model not blamed on key', () async {
      final fake = FakeGeminiTransport([
        GeminiHttpResponse(400,
            utf8.encode('{"error": {"message": "models/xyz is not found."}}')),
      ]);
      final (ok, message) = await testApiKey(
        'AIza-good',
        model: 'xyz',
        transport: fake.call,
      );
      expect(ok, isFalse);
      expect(message, contains('model'));
      expect(message, isNot(contains('AIza-good')));
    });

    test('network error redacts key', () async {
      const secret = 'AIza-topsecret';
      Future<GeminiHttpResponse> failing(
        Uri url, {
        required Map<String, String> headers,
        List<int>? body,
        required Duration timeout,
      }) async {
        throw StateError('boom $secret unreachable');
      }

      final (ok, message) = await testApiKey(secret, transport: failing);
      expect(ok, isFalse);
      expect(message, isNot(contains(secret)));
    });
  });

  group('recommend', () {
    test('strips api key into header, never url', () async {
      final fake = FakeGeminiTransport(
          [GeminiHttpResponse(200, utf8.encode('{}'))]);
      final food = {
        '01.10.2026': {'1&2&3': 'Rajská omáčka'}
      };
      await recommendLunches(food, 'x', '  SECRETKEY \n',
          transport: fake.call);
      expect(fake.calls, isNotEmpty);
      for (final call in fake.calls) {
        expect(call.headers['x-goog-api-key'], 'SECRETKEY');
        expect(call.url.toString(), isNot(contains('SECRETKEY')));
      }
    });

    test('empty gemini answer falls back to local', () async {
      final fake = FakeGeminiTransport(
          [jsonReply('Dnes doporučuji lehké jídlo, dobrou chuť!')]);
      final (html, orders) = await recommendLunches(
        food,
        '',
        'KEY',
        retries: 0,
        transport: fake.call,
        sleep: (_) async {},
      );
      expect(orders, expectedFallback);
      expect(html, isNotEmpty);
    });

    test('hallucinated ids fall back to local', () async {
      final fake = FakeGeminiTransport([
        jsonReply('```json {"99.99.9999": "zzz", "16.09.2026": "nope"}```')
      ]);
      final (_, orders) = await recommendLunches(
        food,
        '',
        'KEY',
        retries: 0,
        transport: fake.call,
        sleep: (_) async {},
      );
      expect(orders, expectedFallback);
    });

    test('partial gemini answer is kept', () async {
      final fake = FakeGeminiTransport(
          [jsonReply('Rybka je super. ```json {"17.09.2026": "b&1&0"}```')]);
      final (_, orders) = await recommendLunches(
        food,
        '',
        'KEY',
        retries: 0,
        transport: fake.call,
        sleep: (_) async {},
      );
      expect(orders, {'17.09.2026': 'b&1&0'});
      expect(fake.calls, hasLength(1)); // accepted first try, no retry
    });
  });

  group('parse and validate', () {
    test('parse json block', () {
      final (clean, orders) = parseRecommendationResponse(
        '• Monday pick\n```json {"01.09.2026": "abc"} ```',
      );
      expect(orders, {'01.09.2026': 'abc'});
      expect(clean, contains('Monday'));
    });

    test('validate rejects other days meal', () {
      const menu = {
        '01.10.2026': {'table1&1&0': 'Guláš', 'table1&2&0': 'Rizoto'},
        '2.10.2026': {'table2&1&0': 'Svíčková', 'table2&2&0': 'Salát'},
      };
      final got = validateRecommendation(
        {'01.10.2026': 'table2&1&0', '02.10.2026': 'table2&2&0'},
        menu,
      );
      expect(got, {'2.10.2026': 'table2&2&0'});
    });

    test('merge falls back to filter for cross-day pick', () {
      const menu = {
        '01.10.2026': {'table1&1&0': 'Guláš', 'table1&2&0': 'Rizoto'},
        '2.10.2026': {'table2&1&0': 'Svíčková', 'table2&2&0': 'Salát'},
      };
      final got = mergeGeminiWithFilter(
        {'01.10.2026': 'table2&1&0'},
        menu,
        today: DateTime(2026, 9, 24),
      );
      expect(got['01.10.2026'], 'table1&1&0'); // filter pick, not 2.10.'s meal
    });

    test('validate drops hallucinations', () {
      const menu = {
        '07.09.2026': {'id1': 'Meal one', 'id2&A': 'Deorder'}
      };
      final got = validateRecommendation(
        {'07.09.2026': 'nope', '99.99.9999': 'id1', '7.9.2026': 'id1'},
        menu,
      );
      expect(got, {'07.09.2026': 'id1'}); // bad id + bad day dropped
    });

    test('local fallback picks high-protein meal', () {
      const menu = {
        '01.09.2026': {'id1': 'Kuřecí prsa', 'id2': 'Vepřová pečeně'}
      };
      final (html, orders) = localFallbackRecommendation(
        menu,
        'hodně bílkovin',
      );
      expect(orders['01.09.2026'], 'id1');
      expect(html, isNotEmpty);
    });
  });

  group('language', () {
    test('texts follow the requested language', () async {
      expect(
        (await recommendLunches({}, '', '', language: 'en')).$1,
        'No menu to recommend from.',
      );
      expect(
        (await recommendLunches({}, '', '', language: 'cs')).$1,
        'Žádný jídelníček k doporučení.',
      );
      expect(await testApiKey('', language: 'en'), (false, 'Missing API key.'));
      final (html, _) = localFallbackRecommendation(
        {
          '01.10.2026': {'1': 'Polévka'}
        },
        '',
        language: 'en',
      );
      expect(html.startsWith('Local recommendation (no AI):'), isTrue);
    });

    test('core t lang override', () {
      expect(t('gemini_missing_key', lang: 'en'), 'Missing API key.');
      expect(t('gemini_missing_key', lang: 'cs'), 'Chybí API klíč.');
      expect(getLanguage(), isIn(['cs', 'en']));
    });
  });
}
