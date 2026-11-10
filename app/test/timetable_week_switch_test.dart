import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_timetable_week_switch.py` (3 cases).
Map<String, Object?> _lesson(DateTime day) => {
      'day': '${day.day}.${day.month}.${day.year}',
      'teacher': 'Novák',
      'subjecttext': 'Matematika',
      'time': '1 (8:00 - 8:45)',
    };

Map<String, Object?> _weekContent(List<Object?> details) => {
      'Days': [
        {
          'Hours': [
            {
              'Atoms': [
                for (final d in details)
                  {
                    'TooltipDetails': jsonEncode(d),
                  }
              ]
            }
          ]
        }
      ]
    };

class _FakeTransport implements HttpTransport {
  final Map<String, Object?> response;
  _FakeTransport(this.response);

  @override
  Future<HttpResponseData> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (url.path == '/login') {
      return HttpResponseData(
        statusCode: 200,
        url: url,
        headers: {
          'content-type': ['text/html; charset=utf-8']
        },
        bodyBytes: utf8.encode(
          '<html><body>\n<form id="formlogin" method="post" action="/login">\n'
          '<input type="hidden" name="returnUrl" value="">\n'
          '<input id="username" name="username" type="text" value="">\n'
          '<input id="password" name="password" type="password">\n'
          '<button id="loginButton" type="submit" name="login" formaction="/Login">'
          'Přihlásit</button>\n</form></body></html>',
        ),
      );
    }
    if (url.path == '/Login') {
      return HttpResponseData(
        statusCode: 302,
        url: url,
        headers: {
          'location': ['https://bakalari.example.cz/dashboard'],
          'set-cookie': ['BakaAuth=t1; Path=/'],
        },
      );
    }
    if (url.path == '/dashboard') {
      return HttpResponseData(
        statusCode: 200,
        url: url,
        headers: {
          'content-type': ['text/html; charset=utf-8']
        },
        bodyBytes: utf8.encode('<html><body>Dashboard</body></html>'),
      );
    }
    return HttpResponseData(
      statusCode: 200,
      url: url,
      headers: {
        'content-type': ['application/json']
      },
      bodyBytes: utf8.encode(jsonEncode(response)),
    );
  }

  @override
  void close() {}
}

BakalariClient _client(DateTime day) {
  final transport = _FakeTransport(_weekContent([_lesson(day)]));
  return BakalariClient(
    {
      'bakalari_url': 'https://bakalari.example.cz',
      'bakalari_username': 'u',
      'bakalari_password': 'p',
      'go_back_weeks': 1,
      'go_forward_weeks': 0,
    },
    transport: transport,
  );
}

void main() {
  test('lessonDaysParsedFromDetails', () {
    final parsed = detailDays([_lesson(DateTime(2026, 9, 7))]);
    expect(parsed, {DateTime(2026, 9, 7)});
  });

  test('stalePreviousWeekIsSkipped', () async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final staleDay = today.subtract(const Duration(days: 7));
    final client = _client(staleDay);
    await client.fetchTimetableWeeks();
    expect(client.timetableSources, isEmpty);
  });

  test('targetWeekIsKept', () async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final client = _client(today);
    await client.fetchTimetableWeeks();
    expect(client.timetableSources, hasLength(1));
  });
}
