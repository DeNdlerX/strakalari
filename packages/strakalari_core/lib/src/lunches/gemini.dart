// Gemini AI lunch recommendations with retries and a local keyword fallback.
//
// Port of strakalari/core/gemini.py. `recommendLunches()` returns
// `(htmlText, {date: mealId})`; picks are validated against the menu before
// anything can be ordered.
//
// Network seam: Gemini calls go through [GeminiTransport], an injectable
// `Future`-based POST. Production passes nothing (a thin `dart:io`
// `HttpClient` default); tests inject fakes, so no test ever touches the
// real API. The key travels in the `x-goog-api-key` header, never in the
// URL, and is redacted from every message and log line.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../i18n.dart';
import '../models.dart';

/// Default Gemini model (config `gemini_model` falls back to this).
const String defaultGeminiModel = 'gemini-3.8-flash';

/// One Gemini HTTPS call: POST [body] to [url], returning status + raw bytes.
///
/// Non-2xx statuses are returned (not thrown) so the caller can tell an
/// invalid key (401/403) apart from a bad model name (400); anything that
/// cannot even produce a response must throw.
typedef GeminiTransport = Future<GeminiHttpResponse> Function(
  Uri url, {
  required Map<String, String> headers,
  List<int>? body,
  required Duration timeout,
});

/// Raw Gemini HTTPS response: status code plus undecoded body bytes.
class GeminiHttpResponse {
  const GeminiHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final List<int> body;
}

/// Non-2xx Gemini answer surfaced with its body for error classification.
class GeminiHttpStatusError implements Exception {
  GeminiHttpStatusError(this.status, this.body);

  final int status;
  final String body;

  @override
  String toString() => 'HTTP Error $status';
}

Future<GeminiHttpResponse> _defaultGeminiTransport(
  Uri url, {
  required Map<String, String> headers,
  List<int>? body,
  required Duration timeout,
}) async {
  final client = HttpClient();
  try {
    final request =
        body == null ? await client.getUrl(url) : await client.postUrl(url);
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close().timeout(timeout);
    final bytes = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
        .timeout(timeout);
    return GeminiHttpResponse(response.statusCode, bytes);
  } finally {
    client.close(force: true);
  }
}

String _menuText(Object? mid, Object? name) => '  ID: $mid | $name';

String buildMenuBlock(Map<Object?, Object?> foodData) {
  final lines = <String>[];
  for (final entry in (foodData).entries) {
    final meals = entry.value;
    final items = <String>[];
    if (meals is Map) {
      for (final meal in meals.entries) {
        if ('${meal.key}'.contains('&-1&')) continue;
        items.add(_menuText(meal.key, meal.value));
      }
    }
    lines.add('Den ${entry.key}:\n${items.join('\n')}');
  }
  return lines.join('\n\n');
}

String buildPrompt(String pref, String menuBlock, [String language = 'cs']) {
  if (language == 'en') {
    return 'You are a lunch picker assistant. User preferences: \'$pref\'.\n'
        'Pick the single best meal for each day from this menu:\n'
        '$menuBlock\n\n'
        'Answer with bullet points explaining the nutritional benefits '
        'and end with a valid JSON block ```json {"DD.MM.YYYY": "meal_ID"} ```.';
  }
  return 'Jsi asistent pro výběr obědů. Uživatel má preference: \'$pref\'.\n'
      'Vyber pro každý den jedno nejvhodnější jídlo z následující nabídky:\n'
      '$menuBlock\n\n'
      'Odpověz ve formátu odrážek s českým vysvětlením nutričních výhod '
      'a na konci uveď platný JSON blok ```json {"DD.MM.YYYY": "ID_jidla"} ```.';
}

final RegExp _tagStrip = RegExp(
  r'</?(script|iframe|object|embed|img|link|meta|style|form|input|button|video|audio)[^>]*>',
  caseSensitive: false,
);

/// Extracts (cleanText, {date: mealId}) from a Gemini reply.
(String, Map<String, String>) parseRecommendationResponse(String text) {
  var recommended = <String, String>{};
  // Strip elements that must never come from a model reply (scripts,
  // frames, embeds, images, forms) before the text is rendered.
  final stripped = text.replaceAll(_tagStrip, '');
  final first = RegExp(r'```json\s*(\{.*?\})\s*```', dotAll: true)
      .firstMatch(stripped);
  if (first != null) {
    try {
      final parsed = json.decode(first.group(1)!);
      if (parsed is Map) {
        recommended = {
          for (final e in parsed.entries) '${e.key}': '${e.value}'
        };
      }
    } catch (_) {
      recommended = {};
    }
  }
  if (recommended.isEmpty) {
    // Greedy-match fallback: a reply with several ```json blocks defeats
    // the first-match above — try every block until one parses.
    for (final block in RegExp(r'```json\s*(.*?)\s*```', dotAll: true)
        .allMatches(stripped)) {
      try {
        final parsed = json.decode(block.group(1)!);
        if (parsed is Map) {
          recommended = {
            for (final e in parsed.entries) '${e.key}': '${e.value}'
          };
          break;
        }
      } catch (_) {
        continue;
      }
    }
  }
  final clean =
      stripped.split('```json').first.trim().replaceAll('\n', '<br>');
  return (clean, recommended);
}

/// Keeps only `{day: mealId}` pairs present on the menu.
///
/// The model may hallucinate IDs or dates; callers must never forward those
/// to ordering. Day keys match canonically (`7.9.2026` and `07.09.2026` are
/// the same day) but the returned day key is the menu's own spelling so
/// downstream `foodDict[day]` hits.
Map<String, String> validateRecommendation(
  Map<Object?, Object?> recommended,
  Map<Object?, Object?> foodData,
) {
  // The meal must be on THAT day's menu: an id borrowed from another day
  // passes a global check but Strava can never order it there.
  final dayIds = <String, Set<String>>{};
  final canonToDay = <String, String>{};
  for (final entry in foodData.entries) {
    final meals = entry.value;
    if (meals is! Map) continue;
    final canon = canonicalDayKey(entry.key);
    dayIds
        .putIfAbsent(canon, () => <String>{})
        .addAll([for (final mid in meals.keys) '$mid']);
    canonToDay.putIfAbsent(canon, () => '${entry.key}');
  }
  final valid = <String, String>{};
  for (final entry in recommended.entries) {
    final midS = '${entry.value}';
    final canon = canonicalDayKey('${entry.key}');
    if (canonToDay.containsKey(canon) &&
        (dayIds[canon] ?? <String>{}).contains(midS)) {
      valid[canonToDay[canon]!] = midS;
    }
  }
  return valid;
}

/// Keyword-based fallback when no API key / API fails. Returns (html, orders).
(String, Map<String, String>) localFallbackRecommendation(
  Map<Object?, Object?> foodData,
  String pref, {
  String language = 'cs',
}) {
  final prefLower = (pref).toLowerCase();
  final htmlLines = <String>[];
  final orders = <String, String>{};
  for (final entry in foodData.entries) {
    final meals = entry.value;
    if (meals is! Map) continue;
    String? bestId;
    String? bestName;
    var bestScore = -999;
    for (final meal in meals.entries) {
      if ('${meal.key}'.contains('&-1&')) continue;
      var score = 0;
      final nameL = '${meal.value}'.toLowerCase();
      if (prefLower.contains('bílkovin') ||
          prefLower.contains('protein') ||
          prefLower.contains('maso')) {
        if (nameL.contains('krůtí') ||
            nameL.contains('kuřec') ||
            nameL.contains('kuře')) {
          score += 30;
        } else if (nameL.contains('hověz') ||
            nameL.contains('steak') ||
            nameL.contains('roštěn')) {
          score += 25;
        } else if (nameL.contains('rybí') ||
            nameL.contains('ryba') ||
            nameL.contains('ryby') ||
            nameL.contains('rybu') ||
            nameL.contains('rybou') ||
            nameL.contains('filé') ||
            nameL.contains('losos') ||
            nameL.contains('tuňák')) {
          score += 25;
        } else if (nameL.contains('vejce') ||
            nameL.contains('tvaroh') ||
            nameL.contains('luštěnin') ||
            nameL.contains('čočka') ||
            nameL.contains('fazole')) {
          score += 20;
        }
      }
      if (prefLower.contains('bez vepř') || prefLower.contains('ne vepř')) {
        if (nameL.contains('vepř') ||
            nameL.contains('sekaná') ||
            nameL.contains('výpeč') ||
            nameL.contains('šunk') ||
            nameL.contains('slanina')) {
          score -= 50;
        }
      }
      if (prefLower.contains('lehk') ||
          prefLower.contains('salát') ||
          prefLower.contains('vegetarián') ||
          prefLower.contains('zelenin')) {
        if (nameL.contains('salát') ||
            nameL.contains('zelenin') ||
            nameL.contains('brokolic') ||
            nameL.contains('špenát')) {
          score += 20;
        }
        if (nameL.contains('smažen') ||
            nameL.contains('tatar') ||
            nameL.contains('majonez')) {
          score -= 20;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestId = '${meal.key}';
        bestName = '${meal.value}';
      }
    }
    if (bestId != null) {
      orders['${entry.key}'] = bestId;
      htmlLines.add('• <b>${entry.key}</b>: $bestName');
    }
  }
  final header = t('gemini_local_heading', lang: language);
  return ('$header${htmlLines.join('<br>')}', orders);
}

Object? _extractText(Object? data) {
  final candidates = (data as Map)['candidates'] as List;
  final content = (candidates[0] as Map)['content'] as Map;
  final parts = content['parts'] as List;
  return (parts[0] as Map)['text'];
}

/// Tries Gemini (with retry), falls back to local keywords.
///
/// With [allowFallback] = false a failed request returns `('', {})`
/// instead of the local keyword picks, so callers can tell a real AI
/// answer from the fallback (the auto-run only stamps real answers).
Future<(String, Map<String, String>)> recommendLunches(
  Map<Object?, Object?> foodData,
  String pref,
  String apiKey, {
  String model = defaultGeminiModel,
  String language = 'cs',
  Duration timeout = const Duration(seconds: 30),
  int retries = 2,
  bool allowFallback = true,
  GeminiTransport? transport,
  Future<void> Function(Duration)? sleep,
}) async {
  (String, Map<String, String>) fallback(Map<Object?, Object?> data) {
    if (!allowFallback) return ('', <String, String>{});
    return localFallbackRecommendation(data, pref, language: language);
  }

  if (foodData.isEmpty) {
    return (t('gemini_no_menu', lang: language), <String, String>{});
  }
  late final String menuBlock;
  try {
    menuBlock = buildMenuBlock(foodData);
  } catch (_) {
    return fallback(foodData);
  }
  final key = apiKey.trim();
  if (key.isEmpty) return fallback(foodData);
  final send = transport ?? _defaultGeminiTransport;
  final prompt = buildPrompt(pref, menuBlock, language);
  final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
  final headers = {'Content-Type': 'application/json', 'x-goog-api-key': key};
  final payload = utf8.encode(json.encode({
    'contents': [
      {
        'parts': [
          {'text': prompt}
        ]
      }
    ]
  }));
  Object? lastErr;
  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      final response = await send(url,
          headers: headers, body: payload, timeout: timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GeminiHttpStatusError(
            response.statusCode, utf8.decode(response.body, allowMalformed: true));
      }
      final data = json.decode(utf8.decode(response.body));
      final text = _extractText(data);
      final (clean, recommended) = parseRecommendationResponse('$text');
      final html = t('gemini_heading', lang: language) + clean;
      // Never forward hallucinated IDs/dates to ordering — and
      // never stage nothing while the menu is full: an empty
      // answer counts as a failure (retry, then local fallback).
      final validOrders = validateRecommendation(recommended, foodData);
      if (validOrders.isNotEmpty) {
        return (html, validOrders);
      }
      lastErr = StateError('Gemini returned no usable meal picks');
    } catch (e) {
      lastErr = e;
    }
    if (attempt < retries) {
      await (sleep ?? Future.delayed)(Duration(seconds: 1 + attempt));
    }
  }
  // Never let the key reach stdout/the log, even via an echoed request.
  final errText = '$lastErr'.replaceAll(key, '***');
  // ignore: avoid_print
  print('Gemini API request failed: $errText');
  return fallback(foodData);
}

/// Lightweight validation of a Gemini API key (no browser needed).
///
/// GETs the single model's metadata endpoint — cheap, no quota burn beyond
/// one read. Returns (ok, message). The key is never embedded in the
/// returned message.
Future<(bool, String)> testApiKey(
  String apiKey, {
  String model = defaultGeminiModel,
  Duration timeout = const Duration(seconds: 20),
  String language = 'cs',
  GeminiTransport? transport,
}) async {
  final key = apiKey.trim();
  if (key.isEmpty) {
    return (false, t('gemini_missing_key', lang: language));
  }
  final modelName = model.trim().isEmpty ? defaultGeminiModel : model.trim();
  final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName');
  final send = transport ?? _defaultGeminiTransport;
  try {
    final response = await send(url,
        headers: {'Accept': 'application/json', 'x-goog-api-key': key},
        timeout: timeout);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GeminiHttpStatusError(response.statusCode,
          utf8.decode(response.body, allowMalformed: true));
    }
    if (response.statusCode == 400) {
      throw GeminiHttpStatusError(response.statusCode,
          utf8.decode(response.body, allowMalformed: true));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GeminiHttpStatusError(response.statusCode,
          utf8.decode(response.body, allowMalformed: true));
    }
    Map<Object?, Object?> data;
    try {
      data = json.decode(utf8.decode(response.body)) as Map;
    } catch (_) {
      data = {};
    }
    final display = '${(data)['displayName'] ?? ''}'.isNotEmpty
        ? '${(data)['displayName']}'
        : modelName;
    return (
      true,
      t('gemini_key_ok', lang: language, args: {'model': display})
    );
  } catch (e) {
    // Never let the key reach the message (it may be echoed in the error).
    final text = '$e'.replaceAll(key, '***');
    final status = e is GeminiHttpStatusError ? e.status : null;
    if (status == 401 || status == 403) {
      return (
        false,
        t('gemini_key_invalid', lang: language, args: {'status': status})
      );
    }
    if (status == 400) {
      // Google returns 400 both for a bad key ("API key not valid")
      // and for a bad request (unknown model). Tell them apart via
      // the response body instead of blaming the key every time.
      String bodyText = '';
      try {
        bodyText = (e as GeminiHttpStatusError).body;
      } catch (_) {
        bodyText = '';
      }
      final low = bodyText.toLowerCase();
      if (low.contains('api key not valid') ||
          low.contains('api_key_invalid')) {
        return (
          false,
          t('gemini_key_invalid', lang: language, args: {'status': 400})
        );
      }
      return (false, t('gemini_bad_request', lang: language));
    }
    final trimmed = text.trim();
    final first = trimmed.isEmpty
        ? 'unknown error'
        : (text.split('\n').first.length > 160
            ? text.split('\n').first.substring(0, 160)
            : text.split('\n').first);
    return (
      false,
      t('gemini_key_check_failed',
          lang: language, args: {'err': '${e.runtimeType}: $first'})
    );
  }
}
