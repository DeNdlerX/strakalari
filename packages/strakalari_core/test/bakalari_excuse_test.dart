import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/cancel.dart';
import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/bakalari/excuse.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';

import 'fake_bakalari.dart';

const String formPage = '<html><head>\n'
    '<link rel="stylesheet" href="../App_Themes/NextBlueTheme/Basicstyl.css?v=1">\n'
    '<link rel="stylesheet" href="/DXR.axd?r=1_73,1_67-AbCd">\n'
    '<script src="/DXR.axd?r=1_11,1_12-AbCd" type="text/javascript"></script>\n'
    '</head><body><form id="formbaka" method="post" action="./komens_zprava.aspx?l=abs">\n'
    '<input type="hidden" name="__EVENTTARGET" value="">\n'
    '<input type="hidden" name="__VIEWSTATE" value="vs-1">\n'
    '<input type="hidden" name="cphmain_cmbRecipient_VI" value="OMLUVENKA">\n'
    '<input type="text" name="ctl00\$cphmain\$cmbMessageType" value="Omluvení absence">\n'
    '<input type="text" name="ctl00\$cphmain\$cbExcuseWholeDay" value="C">\n'
    '<input type="text" name="ctl00\$cphmain\$teachingLesson" value="I">\n'
    '<input type="text" name="ctl00\$cphmain\$specificTime" value="I">\n'
    '<input type="text" name="ctl00\$cphmain\$excuseFromDate" value="05.10.2026">\n'
    '<input id="comboExcuseFromPeriod_VI" name="comboExcuseFromPeriod_VI" type="hidden" />\n'
    '<input type="text" name="ctl00\$cphmain\$comboExcuseFromPeriod" value="">\n'
    '<input type="hidden" name="ctl00\$cphmain\$comboExcuseFromPeriod\$DDD\$L" value="">\n'
    '<input type="text" name="ctl00\$cphmain\$excuseToDate" value="05.10.2026">\n'
    '<input id="comboExcuseToPeriod_VI" name="comboExcuseToPeriod_VI" type="hidden" />\n'
    '<input type="text" name="ctl00\$cphmain\$comboExcuseToPeriod" value="">\n'
    '<input type="hidden" name="ctl00\$cphmain\$comboExcuseToPeriod\$DDD\$L" value="">\n'
    '<input type="hidden" name="cphmain_cmbRecipientType_VI" value="U">\n'
    '<input id="cphmain_cmbRecipient_VI" name="cphmain_cmbRecipient_VI" type="hidden" value="UABCD" />\n'
    '<input type="text" name="ctl00\$cphmain\$cmbRecipient" value="Novák Jan Mgr.">\n'
    '<input type="text" name="ctl00\$cphmain\$cbWithConfirmation" value="I">\n'
    '<input type="text" name="ctl00\$cphmain\$cbCcParent" value="I">\n'
    '<input type="button" name="ctl00\$cphmain\$button_zrusit" value="Zrušit">\n'
    '<input type="submit" name="ctl00\$cphmain\$button_poslat" value="Odeslat" onclick="return sendMessage();" id="button_poslat" />\n'
    '</form>\n'
    '<script>ASPx.createControl(ASPxClientHtmlEditor,\'cphmain_MessageEditor\',\'MessageEditor\','
    '{\'callBack\':function(arg) { },\n'
    '\'uniqueID\':\'ctl00\$cphmain\$MessageEditor\',\'stateObject\':{\'cssFiles\':'
    '[\'../App_Themes/X/styles.css\'],\'clientState\':\'ActiveView|6|\'}});</script>\n'
    '</body></html>';

const String outboxPage = '<html><body><form id="formbaka" method="post" action="./komens.aspx?l=o">\n'
    '<input type="hidden" name="__VIEWSTATE" value="state-1">\n'
    '<input type="hidden" name="ctl00\$cphmain\$hfListType" id="hfListType" value="odeslane">\n'
    '<span id="cphmain_obdobiLabel">5.9.2026 - 5.10.2026</span>\n'
    '</form></body></html>';

const Map<String, List<Map<String, Object?>>> hours = {
  '2026-10-01': [
    {'Caption': '3', 'Begin': 605, 'End': 650},
    {'Caption': '4', 'Begin': 660, 'End': 705},
    {'Caption': '6', 'Begin': 770, 'End': 815},
  ],
  '2026-10-02': [
    {'Caption': '1', 'Begin': 480, 'End': 525},
    {'Caption': '7', 'Begin': 820, 'End': 865},
  ],
};

/// Routes of a school whose outbox gains [sentDetail] once the form posts.
class ExcuseSchool {
  Map<String, Map<String, Object?>> outbox = {
    '501': {
      'Kind': 'OMLUVENKA',
      'DateFrom': '18.9.2026',
      'DateTo': '18.9.2026',
      'HourFrom': {'Caption': '6'},
      'HourTo': {'Caption': '6'},
    },
  };
  final Map<String, Object?>? sentDetail;
  final Object? Function(FakeRequest)? postReply;
  final List<Map<String, String>> posts = [];

  ExcuseSchool({this.sentDetail, this.postReply});

  Object? form(FakeRequest request) {
    posts.add(Uri.splitQueryString(utf8.decode(request.body)));
    if (postReply != null) return postReply!(request);
    if (sentDetail != null) {
      outbox = {'601': sentDetail!, ...outbox};
    }
    return HttpResponseData(
        statusCode: 302,
        url: Uri.parse('$fakeRoot/next/komens_zprava.aspx'),
        headers: {
          'Location': ['/next/komens.aspx?l=o']
        });
  }

  String listing(FakeRequest request) {
    final rows = outbox.keys
        .map((id) =>
            '<table data-idmsg="$id" data-msgtype="OMLUVENKA"></table>')
        .join();
    return dxReply('<div class="komens-messages-wrapper">$rows</div>');
  }

  Map<String, Object?> detail(FakeRequest request) {
    final payload =
        jsonDecode(utf8.decode(request.body)) as Map;
    return {
      'success': true,
      'data': outbox['${payload['idmsg']}']!,
    };
  }

  Object? hoursReply(FakeRequest request) => {
        'success': true,
        'data': hours[request.url.queryParameters['date']] ?? [],
      };

  Map<String, Object?> routes() => {
        'GET /next/komens_zprava.aspx': formPage,
        'POST /next/komens_zprava.aspx': form,
        'GET /Komens/ExcuseHours': hoursReply,
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': listing,
        'POST /Komens/GetMessageDataAsync': detail,
      };
}

Map<String, Object?> lessons(String day, int first, int last) => {
      'Kind': 'OMLUVENKA',
      'DateFrom': day,
      'DateTo': day,
      'HourFrom': {'Caption': '$first'},
      'HourTo': {'Caption': '$last'},
    };

/// Inverse of `ASPx.Str.EncodeHtml`.
String dxDecode(String text) {
  for (final pair in [
    ('&gt;', '>'),
    ('&gtx;', '&gt;'),
    ('&lt;', '<'),
    ('&ltx;', '&lt;'),
    ('&quot;', '"'),
    ('&quotx;', '&quot;'),
    ('&amp;', '&'),
    ('&ampx;', '&amp;'),
  ]) {
    text = text.replaceAll(pair.$1, pair.$2);
  }
  return text;
}

Map<String, Object?> postState(Map<String, String> post, String name) =>
    jsonDecode(dxDecode(post[name]!)) as Map<String, Object?>;

String editorHtml(Map<String, String> post) =>
    dxDecode(postState(post, 'ctl00\$cphmain\$MessageEditor')['html']
        as String);

(BakalariClient, ExcuseSchool, List<String>) excuseClient(
  ExcuseSchool school, {
  Map<String, Object?> Function(Map<String, Object?>)? config,
}) {
  var routes = school.routes();
  final logs = <String>[];
  var conf = Map<String, Object?>.of(fakeConfig);
  if (config != null) conf = config(conf);
  final bak = BakalariClient(conf,
      logger: logs.add, transport: FakeBakalari(routes));
  return (bak, school, logs);
}

void main() {
  group('excusePost', () {
    test('lessonExcusePostsTheFormOnceAndIsConfirmedByTheOutbox',
        () async {
      final school =
          ExcuseSchool(sentDetail: lessons('1.10.2026', 3, 4));
      final (bak, _, _) = excuseClient(school);
      expect(
          await bak.executeExcuse('01.10.2026', '01.10.2026',
              3, 4, 'Omluvte prosím absenci.\nJan'),
          isTrue);
      expect(bak.lastSubmitUncertain, isFalse);
      final [post] = school.posts;
      expect(post['ctl00\$cphmain\$button_poslat'], 'Odeslat');
      expect(post['__VIEWSTATE'], 'vs-1');
      expect(
          (post['ctl00\$cphmain\$cbExcuseWholeDay'],
              post['ctl00\$cphmain\$teachingLesson']),
          ('U', 'C'));
      expect(post['ctl00\$cphmain\$excuseFromDate'],
          post['ctl00\$cphmain\$excuseToDate']);
      expect(post['ctl00\$cphmain\$excuseFromDate'], '01.10.2026');
      expect(post['comboExcuseFromPeriod_VI'], '605');
      expect(post['comboExcuseToPeriod_VI'], '705');
      expect(
          post['ctl00\$cphmain\$comboExcuseFromPeriod'],
          '3 (10:05 - 10:50)');
      expect(post['ctl00\$cphmain\$comboExcuseToPeriod'],
          '4 (11:00 - 11:45)');
      expect(post['cphmain_cmbRecipient_VI'], 'UABCD');
      expect(post['ctl00\$cphmain\$cbWithConfirmation'], 'C');
      expect(post['ctl00\$cphmain\$cbCcParent'], 'U');
      expect(post.containsKey('ctl00\$cphmain\$button_zrusit'), isFalse);
      expect(
          postState(post, 'ctl00\$cphmain\$excuseFromDate\$State')['rawValue'],
          '1790812800000');
      expect(editorHtml(post),
          '<p>Omluvte prosím absenci.</p><p>Jan</p>');
      expect(post['DXScript'], '1_11,1_12');
      expect(post['DXMVCEditorsValues'],
          contains('"cphmain_teachingLesson":true'));
    });

    test('wholeDayExcusePostsTheDayRange', () async {
      final school = ExcuseSchool(sentDetail: {
        'Kind': 'OMLUVENKA',
        'DateFrom': '1.10.2026',
        'DateTo': '2.10.2026',
        'HourFrom': null,
        'HourTo': null,
      });
      final (bak, _, _) = excuseClient(school);
      expect(
          await bak.executeExcuse('01.10.2026', '02.10.2026', null, null,
              'Nemoc', true),
          isTrue);
      final [post] = school.posts;
      expect(
          (post['ctl00\$cphmain\$cbExcuseWholeDay'],
              post['ctl00\$cphmain\$teachingLesson']),
          ('C', 'I'));
      expect(post['ctl00\$cphmain\$excuseToDate'], '02.10.2026');
      // The pickers as the form leaves them: first lesson of day one,
      // last of the last day.
      expect(post['comboExcuseFromPeriod_VI'], '605');
      expect(post['comboExcuseToPeriod_VI'], '865');
    });

    test('lessonNotInTheTimetableIsNeverPosted', () async {
      final school = ExcuseSchool();
      final (bak, _, _) = excuseClient(school);
      expect(
          await bak.executeExcuse(
              '01.10.2026', '01.10.2026', 1, 1),
          isFalse);
      expect(bak.lastSubmitUncertain, isFalse);
      expect(school.posts, isEmpty);
    });

    test('unreadableOutboxBeforeSendingMeansNothingIsPosted', () async {
      final school =
          ExcuseSchool(sentDetail: lessons('1.10.2026', 3, 3));
      final routes = school.routes();
      routes['POST /next/komens.aspx'] =
          dxReply('<div>Chyba</div>');
      final logs = <String>[];
      final bak = BakalariClient(Map.of(fakeConfig),
          logger: logs.add, transport: FakeBakalari(routes));
      expect(
          await bak.executeExcuse(
              '01.10.2026', '01.10.2026', 3, 3),
          isFalse);
      expect(bak.lastSubmitUncertain, isFalse);
      expect(school.posts, isEmpty);
    });

    test('postMissingFromTheOutboxIsUncertainAndNeverRepeated',
        () async {
      final school = ExcuseSchool(sentDetail: null);
      final (bak, _, _) = excuseClient(school);
      expect(
          await bak.executeExcuse(
              '01.10.2026', '01.10.2026', 3, 3),
          isFalse);
      expect(bak.lastSubmitUncertain, isTrue);
      expect(school.posts, hasLength(1));
    });

    test('otherExcuseAppearingDoesNotConfirmThisOne', () async {
      final school =
          ExcuseSchool(sentDetail: lessons('1.10.2026', 6, 6));
      final (bak, _, _) = excuseClient(school);
      expect(
          await bak.executeExcuse(
              '01.10.2026', '01.10.2026', 3, 4),
          isFalse);
      expect(bak.lastSubmitUncertain, isTrue);
    });

    group('networkFailure', () {
      // Phase, not error code, decides: only a ConnectFailure (DNS +
      // connect, before any request byte left) means "never sent".
      // Anything the fake throws from the post handler models a failure
      // after openUrl returned, i.e. "maybe sent" — even ETIMEDOUT.
      for (final (name, error, uncertain) in [
        (
          'connectRefused',
          ConnectFailure(SocketException('Connection refused')),
          false,
        ),
        (
          'connectTimedOut',
          ConnectFailure(TimeoutException('connect timed out')),
          false,
        ),
        (
          'readTimedOut',
          TimeoutException('read timed out'),
          true,
        ),
        (
          'resetAfterSend',
          SocketException('Connection reset by peer'),
          true,
        ),
        (
          'timedOutAfterSend',
          SocketException('Connection timed out',
              osError: OSError('', 110)),
          true,
        ),
      ]) {
        test(
            'tellsNeverSentFromMaybeSent ($name)',
            () async {
          late final ExcuseSchool school;
          Object? fail(FakeRequest request) {
            throw error;
          }

          school = ExcuseSchool(postReply: fail);
          final (bak, _, _) = excuseClient(school);
          expect(
              await bak.executeExcuse(
                  '01.10.2026', '01.10.2026', 3, 3),
              isFalse);
          expect(bak.lastSubmitUncertain, uncertain);
          expect(school.posts, hasLength(1));
        });
      }
    });

    test('expiredSessionOnThePostIsNotSentAndNotRetried', () async {
      late final ExcuseSchool school;
      HttpResponseData loginPage(FakeRequest request) {
        return HttpResponseData(
            statusCode: 302,
            url: Uri.parse('$fakeRoot/next/komens_zprava.aspx'),
            headers: {
              'Location': ['/login']
            });
      }

      school = ExcuseSchool(postReply: loginPage);
      final server = FakeBakalari(school.routes());
      final bak = BakalariClient(Map.of(fakeConfig),
          transport: server);
      expect(
          await bak.executeExcuse(
              '01.10.2026', '01.10.2026', 3, 3),
          isFalse);
      expect(bak.lastSubmitUncertain, isFalse);
      expect(school.posts, hasLength(1));
      expect(server.logins, 1);
    });

    test('cancelBeforeThePostSendsNothing', () async {
      final school =
          ExcuseSchool(sentDetail: lessons('1.10.2026', 3, 3));
      final (bak, _, _) = excuseClient(school);
      bak.cancelRequested = true;
      await expectLater(
          bak.executeExcuse('01.10.2026', '01.10.2026', 3, 3),
          throwsA(isA<CancelledError>()));
      expect(school.posts, isEmpty);
      expect(bak.lastSubmitUncertain, isFalse);
    });

    test('defaultTextComesFromTheTemplates', () async {
      final school =
          ExcuseSchool(sentDetail: lessons('1.10.2026', 3, 3));
      final (bak, _, _) = excuseClient(school,
          config: (conf) => conf
            ..['late_income_excuses'] = [
              'Pozdní příchod {date}, hodina {lessons}.'
            ]);
      expect(
          await bak.executeExcuse('01.10.2026', '01.10.2026', 3, 3,
              null, false, 'income'),
          isTrue);
      expect(
          editorHtml(school.posts.single)
              .startsWith('<p>Pozdní příchod 01.10.2026, hodina 3.</p>'),
          isTrue);
    });

    test('postbackWithoutNowReadsTheClock', () {
      // Python `datetime.now()`: the form's timestamps follow the clock.
      List<(String, String)> build({DateTime? now}) => excusePostback(
          formPage,
          dayFrom: DateTime(2026, 10, 1),
          dayTo: DateTime(2026, 10, 1),
          wholeDay: true,
          text: 'x',
          now: now);
      final at = DateTime(2026, 10, 5, 22, 14);
      final viaClock = withClock(Clock.fixed(at), () => build());
      expect(viaClock, build(now: at));
    });

    test('editorFieldMatchesTheBrowserByteForByte', () {
      // Captured from the real form: the HTML is encoded twice by
      // DevExpress.
      final posted = excusePostback(
          formPage,
          dayFrom: DateTime(2026, 10, 1),
          dayTo: DateTime(2026, 10, 1),
          wholeDay: true,
          text: 'a&b "c" \'d\' <e> čřž\nJan',
          now: DateTime(2026, 10, 5, 22, 14));
      final fields = <String, String>{
        for (final field in posted) field.$1: field.$2
      };
      expect(fields['ctl00\$cphmain\$MessageEditor'],
          '{&quot;cssFiles&quot;:[&quot;../App_Themes/X/styles.css&quot;],&quot;clientState&quot;:'
          '&quot;ActiveView|6|&quot;,&quot;validationState&quot;:&quot;&quot;,&quot;html&quot;:&quot;'
          '&amp;lt;p&amp;gt;a&amp;ampx;ampx;b &amp;ampx;quot;c&amp;ampx;quot; &amp;ampx;#39;d&amp;ampx;#39; '
          '&amp;ampx;lt;e&amp;ampx;gt; čřž&amp;lt;/p&amp;gt;&amp;lt;p&amp;gt;Jan&amp;lt;/p&amp;gt;&quot;}');
    });
  });
}
