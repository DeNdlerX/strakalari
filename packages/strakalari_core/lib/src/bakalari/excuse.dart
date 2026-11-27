// The Bakaláři excuse form (Komens → Omluvení absence) over plain HTTP.
//
// Port of strakalari/core/bakalari_excuse.py.
//
// Sends exactly the postback the web form sends when "Odeslat" is clicked:
// the form's own fields from its raw HTML plus the client state its
// DevExpress controls add in the browser (dates, lesson pickers, the text
// editor). The post is one request, never retried; only the Komens outbox
// confirms that it went out.
import 'dart:convert';

import 'package:clock/clock.dart';

import '../automation/cancel.dart';
import '../error_report.dart';
import '../models.dart';
import '../storage/helpers.dart';
import 'client.dart';
import 'data.dart';
import 'http_session.dart';

/// The excuse form, its lesson-hours endpoint and the "Odeslat" button.
const String _formPath = '/next/komens_zprava.aspx?l=abs';
const String _hoursPath = '/Komens/ExcuseHours';
const (String, String) _sendButton =
    ('ctl00\$cphmain\$button_poslat', 'Odeslat');
const String _p = 'ctl00\$cphmain\$';

/// Popup / dropdown / list states as a freshly loaded, untouched form posts
/// them.
const Map<String, String> _closed = {
  'windowsState': '0:0:-1:0:0:0:-10000:-10000:1:0:0:0'
};
const Map<String, String> _list = {'CustomCallback': ''};
const (List<String>, String) _editorFallback = (
  ['../App_Themes/NextBlueTheme/HtmlEditor/styles.css'],
  'ActiveView|6|DesignCurrentWidth|3|100CurrentHeight|3|100IsPercentWidth|1|1'
      'ForeColorPalette|0|Ribbon|0|'
);

/// `605` → `10:05`.
String minutesText(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Combo text of one lesson, as the form shows it: `3 (10:05 - 10:50)`.
String hourText(Map<String, Object?> item) {
  final times =
      '(${minutesText(item['Begin'] as int)} - ${minutesText(item['End'] as int)})';
  final caption = '${item['Caption'] ?? ''}'.trim();
  return caption.isEmpty ? times : '$caption $times';
}

/// The lesson numbered [number] in [items], or null.
Map<String, Object?>? lesson(List<Object?> items, Object? number) {
  final want = '$number'.trim();
  for (final item in items) {
    if (item is Map &&
        '${item['Caption'] ?? ''}'.trim() == want) {
      return Map<String, Object?>.from(item);
    }
  }
  return null;
}

/// The editor HTML of plain [text] (one paragraph per line, escaped the
/// way the editor's `GetHtml` returns it).
String textToHtml(String? text) {
  String esc(String line) {
    for (final pair in [
      ('&', '&amp;'),
      ('<', '&lt;'),
      ('>', '&gt;'),
      ('"', '&quot;'),
      ("'", '&#39;'),
    ]) {
      line = line.replaceAll(pair.$1, pair.$2);
    }
    return line.isEmpty ? '&nbsp;' : line;
  }

  final lines = (text ?? '').split('\n');
  if (lines.length == 1 && lines.single.isEmpty) {
    return '<p>${esc('')}</p>';
  }
  return lines.map((line) => '<p>${esc(line)}</p>').join();
}

/// `new Date(…)` as DevExpress writes it into `DXMVCEditorsValues`.
/// [includeTime] distinguishes datetimes from plain dates.
String jsDate(DateTime moment, {bool includeTime = false}) {
  if (!includeTime) {
    return 'new Date(${moment.year},${moment.month - 1},${moment.day})';
  }
  return 'new Date(${moment.year},${moment.month - 1},${moment.day},'
      '${moment.hour},${moment.minute},${moment.second},'
      '${moment.millisecond})';
}

/// Date editors keep the calendar date as UTC midnight in milliseconds.
Map<String, Object?> dateState(DateTime day) {
  // UTC arithmetic: pure calendar days, no daylight-saving skew (a local
  // midnight difference can be an hour short and truncate a day off).
  final midnight = DateTime.utc(day.year, day.month, day.day);
  return {
    'rawValue':
        '${midnight.difference(DateTime.utc(1970, 1, 1)).inDays * 86400000}',
    'useMinDateInsteadOfNull': false,
  };
}

/// The calendar popup state of a date editor.
Map<String, Object?> calendarState(DateTime day) {
  final shown =
      '${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}/${day.year}';
  return {
    'visibleDate': shown,
    'initialVisibleDate': shown,
    'selectedDates': [shown],
  };
}

/// `(DXScript, DXCss)`: the resources the loaded page holds, as the
/// DevExpress client reports them with every post.
(String, String) pageResources(String pageHtml) {
  final scripts = <String>[];
  for (final match in RegExp(
          '<script[^>]*src="[^"]*DXR\\.axd\\?r=([^"&]+)"')
      .allMatches(pageHtml)) {
    final group = match.group(1)!;
    final base = group.contains('-')
        ? group.substring(0, group.lastIndexOf('-'))
        : group;
    scripts.addAll(base.split(','));
  }
  final css = <String>[];
  for (final match in RegExp('<link[^>]*href="([^"]+)"')
      .allMatches(pageHtml)) {
    final href = match.group(1)!.replaceAll('&amp;', '&');
    final resource =
        RegExp('DXR\\.axd\\?r=([^&]+)').firstMatch(href);
    if (resource == null) {
      css.add(href);
    } else {
      final group = resource.group(1)!;
      final base = group.contains('-')
          ? group.substring(0, group.lastIndexOf('-'))
          : group;
      css.addAll(base.split(','));
    }
  }
  return (scripts.join(','), css.join(','));
}

/// `(cssFiles, clientState)` of the text editor's initial state object.
(List<String>, String) editorDefaults(String pageHtml) {
  final match = RegExp("'uniqueID':'ctl00\\\$cphmain\\\$MessageEditor',"
          "'stateObject':\\{'cssFiles':\\[([^\\]]*)\\],"
          "'clientState':'([^']*)'\\}")
      .firstMatch(pageHtml);
  if (match == null) return _editorFallback;
  final files = RegExp("'([^']*)'")
      .allMatches(match.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
  return (files, match.group(2)!);
}

/// A text the user picked for one excuse with its placeholders (`{date}`,
/// `{lessons}`, `{subject}`, `{signature}`) filled in the way an automatic
/// send fills the templates (`Strakalari.defaultExcuseText`); the rest is
/// sent as written.
String fillExcusePlaceholders(
  String text, {
  required String dayStart,
  required String dayEnd,
  required bool wholeDay,
  Object? startLesson,
  Object? endLesson,
  String? excuseType,
  String signature = '',
}) {
  final String date;
  final String lessons;
  if (wholeDay) {
    date = dayStart == dayEnd ? dayStart : '$dayStart – $dayEnd';
    lessons = '';
  } else if (excuseType == 'income' || excuseType == 'soon') {
    date = dayStart;
    lessons = '$startLesson';
  } else {
    date = dayStart;
    lessons = '$startLesson' == '$endLesson'
        ? '$startLesson.'
        : '$startLesson. – $endLesson.';
  }
  return text
      .replaceAll('{date}', date)
      .replaceAll('{lessons}', lessons)
      .replaceAll('{subject}', '')
      .replaceAll('{signature}', signature);
}

/// `dd.MM.yyyy` for form fields.
String _czDay(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.${day.year}';

/// `yyyy-MM-dd` for the hours endpoint.
String _isoDay(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// `[(name, value)]` of the "Odeslat" postback for one excuse.
///
/// [hourFrom] / [hourTo] are `/Komens/ExcuseHours` items (the lesson
/// pickers' values are minutes since midnight: the start lesson's begin
/// and the end lesson's end). Whole-day excuses post the pickers as the
/// form leaves them (first lesson of the first day, last of the last).
List<(String, String)> excusePostback(
  String pageHtml, {
  required DateTime dayFrom,
  required DateTime dayTo,
  required bool wholeDay,
  Map<String, Object?>? hourFrom,
  Map<String, Object?>? hourTo,
  required String text,
  DateTime? now,
}) {
  final effectiveNow = now ?? clock.now();
  final fields = formFields(pageHtml);
  final values = <String, String>{
    for (final field in fields) field.$1: field.$2
  };
  final recipient = values['cphmain_cmbRecipient_VI'] ?? '';
  final recipientType = values['cphmain_cmbRecipientType_VI'] ?? '';
  final fromMinutes = hourFrom?['Begin'] as int?;
  final toMinutes = hourTo?['End'] as int?;
  final nowMs = '${effectiveNow.millisecondsSinceEpoch}';
  final (cssFiles, clientState) = editorDefaults(pageHtml);
  final editor = dxState({
    'cssFiles': cssFiles,
    'clientState': clientState,
    'validationState': '',
    'html': dxEncodeHtml(textToHtml(text)),
  });

  final overrides = <String, String>{
    '${_p}cbExcuseWholeDay': wholeDay ? 'C' : 'U',
    '${_p}teachingLesson': wholeDay ? 'I' : 'C',
    '${_p}excuseFromDate': _czDay(dayFrom),
    '${_p}excuseToDate': _czDay(dayTo),
    'comboExcuseFromPeriod_VI':
        fromMinutes == null ? '' : '$fromMinutes',
    '${_p}comboExcuseFromPeriod':
        hourFrom == null ? '' : hourText(hourFrom),
    '${_p}comboExcuseFromPeriod\$DDD\$L':
        fromMinutes == null ? '' : '$fromMinutes',
    'comboExcuseToPeriod_VI': toMinutes == null ? '' : '$toMinutes',
    '${_p}comboExcuseToPeriod': hourTo == null ? '' : hourText(hourTo),
    '${_p}comboExcuseToPeriod\$DDD\$L':
        toMinutes == null ? '' : '$toMinutes',
    // The page's script forces "require confirmation" on for excuses
    // and clears the copy / e-mail boxes.
    '${_p}cbWithConfirmation': 'C',
    for (final box in [
      'cbMailNotification',
      'cbCcClassTeacher',
      'cbCcDirector',
      'cbCcParent',
      'cbCcStudent'
    ])
      '$_p$box': 'U',
  };
  final posted = [
    for (final field in fields)
      (field.$1, overrides[field.$1] ?? field.$2)
  ];

  // Client state the DevExpress controls add in the browser.
  final validityEnd = addDays(effectiveNow, 14);

  List<(String, String)> combo(String name) => [
        ('$_p$name\$DDDState', dxState(_closed)),
        ('$_p$name\$DDD\$L\$State', dxState(_list)),
      ];

  List<(String, String)> dateEdit(String name, DateTime day) => [
        ('$_p$name\$DDDState', dxState(_closed)),
        ('$_p$name\$DDD\$C', dxState(calendarState(day))),
      ];

  final timeState = dxState(
      {'rawValue': nowMs, 'useMinDateInsteadOfNull': false});
  final added = [
    ...combo('cmbMessageType'),
    ('${_p}cmbTypeOfRating\$State', dxState({'rawValue': ''})),
    ...combo('cmbTypeOfRating'),
    ('${_p}excuseFromDate\$State', dxState(dateState(dayFrom))),
    ...dateEdit('excuseFromDate', effectiveNow),
    ...combo('comboExcuseFromPeriod'),
    ('${_p}excuseFromTime\$State', timeState),
    ('${_p}excuseToDate\$State', dxState(dateState(dayTo))),
    ...dateEdit('excuseToDate', effectiveNow),
    ...combo('comboExcuseToPeriod'),
    ('${_p}excuseToTime\$State', timeState),
    ...combo('cmbRecipientType'),
    ...combo('cmbRecipient'),
    ('${_p}cplRecipientState', dxState(_closed)),
    ('${_p}cplRecipient\$lbRecipients\$State', dxState(_list)),
    ('${_p}cplRecipient\$lbChoosenRecipients\$State', dxState(_list)),
    ...combo('cplRecipient\$cbGroupsSelection'),
    ('${_p}pcGroupNameState', dxState(_closed)),
    ...combo('cmbPostValidity'),
    ('${_p}deValidityStart\$State', dxState(
        {'rawValue': nowMs, 'useMinDateInsteadOfNull': false})),
    ...dateEdit('deValidityStart', effectiveNow),
    ('${_p}deValidityEnd\$State', dxState({
      'rawValue': '${validityEnd.millisecondsSinceEpoch}',
      'useMinDateInsteadOfNull': false
    })),
    ...dateEdit('deValidityEnd', validityEnd),
    ('${_p}MessageEditor', editor),
    ('${_p}MessageEditor\$TD\$T0',
        dxState({'selectedItemIndexPath': '', 'checkedState': ''})),
    ('${_p}MessageEditor\$SPC\$TPCHC0\$TC\$ctl01\$SrchBtnEdit\$State',
        dxState({'rawValue': ''})),
    ('${_p}MessageEditor\$SPCState',
        dxState({'windowsState': '${_closed['windowsState']};${_closed['windowsState']}'})),
    ('${_p}MessageEditor\$SPC\$ctl39\$ResultList\$State',
        dxState(_list)),
    ('${_p}MessageEditor\$DPPState', dxState(_closed)),
    ('pcAttachments_MessageState', dxState(_closed)),
    ('${_p}pcErrorState', dxState(_closed)),
    ('${_p}pcWarningState', dxState(_closed)),
    _sendButton,
    ('ctl00\$pcConfirmDialogState', dxState(_closed)),
  ];
  final (scripts, css) = pageResources(pageHtml);
  final editors = <(String, String)>[
    ('"cphmain_cmbMessageType_DDD_L"', '["OMLUVENKA"]'),
    ('"cphmain_cbExcuseWholeDay"', wholeDay ? 'true' : 'false'),
    ('"cphmain_teachingLesson"', wholeDay ? 'null' : 'true'),
    ('"cphmain_specificTime"', 'null'),
    ('"cphmain_cmbTypeOfRating_DDD_L"', '[]'),
    ('"cphmain_cmbTypeOfRating"', 'null'),
    ('"cphmain_RatingScale"', '0'),
    ('"cphmain_excuseFromDate"', jsDate(dayFrom)),
    ('"comboExcuseFromPeriod_DDD_L"',
        fromMinutes == null ? '[]' : '[$fromMinutes]'),
    ('"cphmain_excuseFromTime"', jsDate(effectiveNow, includeTime: true)),
    ('"cphmain_excuseToDate"', jsDate(dayTo)),
    ('"comboExcuseToPeriod_DDD_L"',
        toMinutes == null ? '[]' : '[$toMinutes]'),
    ('"cphmain_excuseToTime"', jsDate(effectiveNow, includeTime: true)),
    ('"cphmain_cmbRecipientType_DDD_L"', jsonEncode([recipientType])),
    ('"cphmain_cmbRecipient_DDD_L"', jsonEncode([recipient])),
    ('"cphmain_cplRecipient_tbRecipientSearch"', 'null'),
    ('"cphmain_cplRecipient_lbRecipients"', '[]'),
    ('"cphmain_cplRecipient_lbChoosenRecipients"', '[]'),
    ('"cphmain_cplRecipient_cbGroupsSelection_DDD_L"', '[]'),
    ('"cphmain_cplRecipient_cbGroupsSelection"', 'null'),
    ('"cphmain_pcGroupName_tbGroupName"', 'null'),
    ('"cmbPostValidity_DDD_L"', '["V"]'),
    ('"cmbPostValidity"', '"V"'),
    ('"cphmain_deValidityStart"',
        jsDate(effectiveNow, includeTime: true)),
    ('"cphmain_deValidityEnd"', jsDate(validityEnd, includeTime: true)),
    ('"cphmain_cbMailNotification"', 'false'),
    ('"cphmain_cbCcClassTeacher"', 'false'),
    ('"cphmain_cbCcDirector"', 'false'),
    ('"cphmain_cbCcParent"', 'false'),
    ('"cphmain_cbCcStudent"', 'false'),
    ('"cphmain_tbTitle"', 'null'),
    ('"cphmain_MessageEditor_SPC_TPCHC0_ctl01_0_SrchBtnEdit_0"', 'null'),
    ('"cphmain_MessageEditor_SPC_ctl39_SrchBtnEdit"', 'null'),
    ('"cphmain_MessageEditor_SPC_ctl39_ReplaceTb"', 'null'),
    ('"cphmain_MessageEditor_SPC_ctl39_ResultList"', '[]'),
    ('"cphmain_MessageEditor_SPC_ctl39_MatchCase"', 'null'),
    ('"comboExcuseFromPeriod"',
        fromMinutes == null ? 'null' : '$fromMinutes'),
    ('"comboExcuseToPeriod"', toMinutes == null ? 'null' : '$toMinutes'),
    ('"cphmain_cmbRecipient"', jsonEncode(recipient)),
    ('"cphmain_cmbRecipientType"', jsonEncode(recipientType)),
    ('"cphmain_cmbMessageType"', '"OMLUVENKA"'),
    ('"cphmain_cbWithConfirmation"', 'true'),
  ];
  return [
    ...posted,
    ...added,
    ('DXScript', scripts),
    ('DXCss', css),
    (
      'DXMVCEditorsValues',
      '{${editors.map((e) => '${e.$1}:${e.$2}').join(',')}}'
    ),
  ];
}

/// Whether the outbox detail's date is [day].
bool sameDay(Object? value, DateTime day) {
  final parsed = parseCzDate('${value ?? ''}'.trim());
  return parsed != null &&
      parsed.year == day.year &&
      parsed.month == day.month &&
      parsed.day == day.day;
}

/// Excuse sending on top of [DataMixin]'s outbox reading.
///
/// Mixin of [BakalariClientBase]; uses its session state.
mixin ExcuseFormMixin on BakalariClientBase, DataMixin {
  /// The excuse text for one pending excuse (templates first, built-in
  /// fallback when they are all blank).
  String excuseText(
    String dayStart,
    String dayEnd,
    Object? startLesson,
    Object? endLesson,
    bool isDays,
    String? excuseType,
  ) {
    String firstText(List<String>? templates, String fallback) {
      // Skip blank templates: they would submit an empty excuse.
      for (final String candidate in templates ?? <String>[]) {
        if (candidate.trim().isNotEmpty) return candidate;
      }
      return fallback;
    }

    if (isDays) {
      final dateRange =
          dayStart == dayEnd ? dayStart : '$dayStart – $dayEnd';
      return formatExcuseTemplate(
          firstText(longAbsenceExcuses, 'Omluvte prosím absenci.'),
          dateStr: dateRange,
          signatureStr: signature);
    }
    final kind = (excuseType ?? '').toLowerCase();
    final String lessonsRange;
    final List<String> templates;
    final String fallback;
    if (kind == 'income') {
      lessonsRange = '$startLesson';
      templates = lateIncomeExcuses;
      fallback = 'Omluvte prosím pozdní příchod.';
    } else if (kind == 'soon') {
      lessonsRange = '$startLesson';
      templates = leftSoonExcuses;
      fallback = 'Omluvte prosím předčasný odchod.';
    } else {
      lessonsRange = '$startLesson' == '$endLesson'
          ? '$startLesson.'
          : '$startLesson. – $endLesson.';
      templates = shortAbsenceExcuses;
      fallback = 'Omluvte prosím absenci.';
    }
    return formatExcuseTemplate(
        firstText(templates, fallback),
        dateStr: dayStart,
        lessonsStr: lessonsRange,
        signatureStr: signature);
  }

  /// The student's lessons on [day] as the form offers them (`Caption`,
  /// `Begin`, `End`).
  Future<List<Map<String, Object?>>> excuseHours(
      BakalariSession session, DateTime day) async {
    final items = await session.json(
        'GET', _hoursPath,
        queryParams: {'date': _isoDay(day)});
    if (items is! List) return [];
    return [
      for (final item in items)
        if (item is Map &&
            item.containsKey('Begin') &&
            item.containsKey('End'))
          Map<String, Object?>.from(item)
    ];
  }

  /// `(fields, summary)` of the postback, or null when the excuse
  /// cannot be filled in (nothing is sent then).
  Future<(List<(String, String)>, String)?> prepareExcuse(
    String dayStart,
    String dayEnd, [
    Object? startLesson,
    Object? endLesson,
    String? customText,
    bool isDays = false,
    String? excuseType,
  ]) async {
    final dayFrom = parseCzDate(dayStart);
    final dayTo = parseCzDate(dayEnd);
    if (dayFrom == null || dayTo == null || dayTo.isBefore(dayFrom)) {
      log('Warning: excuse dates not understood '
          '($dayStart – $dayEnd), not sending.');
      return null;
    }
    final wholeDay =
        isDays || startLesson == null || endLesson == null;

    final session = bakalariSession();
    final page = await session.getHtml(_formPath);
    if (!page.contains(_sendButton.$1)) {
      throw StateError('the excuse form did not load (format changed?)');
    }
    final values = <String, String>{
      for (final field in formFields(page)) field.$1: field.$2
    };
    if ((values['cphmain_cmbRecipient_VI'] ?? '').trim().isEmpty) {
      throw StateError('the excuse form has no recipient preselected');
    }
    final hoursFrom = await excuseHours(session, dayFrom);
    final hoursTo =
        dayTo == dayFrom ? hoursFrom : await excuseHours(session, dayTo);
    final Map<String, Object?>? hourFrom;
    final Map<String, Object?>? hourTo;
    final String what;
    final dayRange =
        dayTo == dayFrom ? '' : ' – ${_czDay(dayTo)}';
    if (wholeDay) {
      hourFrom = hoursFrom.isNotEmpty ? hoursFrom.first : null;
      hourTo = hoursTo.isNotEmpty ? hoursTo.last : null;
      what = '${_czDay(dayFrom)}$dayRange, whole days';
    } else {
      hourFrom = lesson(hoursFrom, startLesson);
      hourTo = lesson(hoursTo, endLesson);
      final missing = [
        for (final pair in [(startLesson, hourFrom), (endLesson, hourTo)])
          if (pair.$2 == null) '${pair.$1}'
      ];
      if (missing.isNotEmpty) {
        log('Warning: lesson ${missing.join(', ')} is not in your '
            'timetable on the excuse form for $dayStart, not sending.');
        return null;
      }
      what = '${_czDay(dayFrom)}$dayRange'
          ', lessons $startLesson–$endLesson '
              '(${minutesText(hourFrom!['Begin'] as int)}'
              '–${minutesText(hourTo!['End'] as int)})';
    }
    final text = (customText != null && customText.isNotEmpty)
        ? fillExcusePlaceholders(customText,
            dayStart: dayStart,
            dayEnd: dayEnd,
            wholeDay: wholeDay,
            startLesson: startLesson,
            endLesson: endLesson,
            excuseType: excuseType,
            signature: signature)
        : excuseText(dayStart, dayEnd, startLesson, endLesson,
            wholeDay, excuseType);
    if (text.trim().isEmpty) {
      log('Warning: empty excuse text, not sending.');
      return null;
    }
    final fields = excusePostback(page,
        dayFrom: dayFrom,
        dayTo: dayTo,
        wholeDay: wholeDay,
        hourFrom: hourFrom,
        hourTo: hourTo,
        text: text);
    final recipient = values['${_p}cmbRecipient'] ?? '';
    final preview = text.split(RegExp(r'\s+')).join(' ');
    return (
      fields,
      '$what, to $recipient: ${preview.substring(0, preview.length > 120 ? 120 : preview.length)}'
    );
  }

  /// True when a new excuse for exactly these days (and lessons) is in
  /// Komens → Odeslané.
  Future<bool> confirmedInOutbox(
    BakalariSession session,
    Set<String> before,
    DateTime dayFrom,
    DateTime dayTo,
    Object? startLesson,
    Object? endLesson,
    bool wholeDay,
  ) async {
    final (_, ids) = await fetchOutboxIds(session, 500);
    for (final msgId in ids) {
      if (before.contains(msgId)) continue;
      final detail = await DataMixin.fetchOutboxDetail(session, msgId)
              as Map? ??
          {};
      if (!(sameDay(detail['DateFrom'], dayFrom) &&
          sameDay(detail['DateTo'], dayTo))) {
        continue;
      }
      if (wholeDay) return true;
      final captions = [
        for (final key in ['HourFrom', 'HourTo'])
          '${(detail[key] as Map? ?? {})['Caption'] ?? ''}'.trim()
      ];
      if (captions[0] == '$startLesson'.trim() &&
          captions[1] == '$endLesson'.trim()) {
        return true;
      }
    }
    return false;
  }

  /// Sends one excuse. True only when Komens → Odeslané shows it.
  ///
  /// False has two meanings, told apart by [lastSubmitUncertain]:
  /// false there = certainly not sent (not prepared, outbox unreadable
  /// before sending, the post never left, or the session had expired);
  /// true = the post went out but the outbox does not show it. The
  /// caller must then never re-send until the outbox settles it.
  Future<bool> executeExcuse(
    String dayStart,
    String dayEnd, [
    Object? startLesson,
    Object? endLesson,
    String? customText,
    bool isDays = false,
    String? excuseType,
  ]) async {
    lastSubmitUncertain = false;
    raiseIfCancelledNow();
    final prepared = await prepareExcuse(dayStart, dayEnd, startLesson,
        endLesson, customText, isDays, excuseType);
    if (prepared == null) return false;
    final (fields, summary) = prepared;
    final session = bakalariSession();
    late final Set<String> before;
    try {
      before = (await fetchOutboxIds(session, 500)).$2.toSet();
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Excuse not sent: Komens → Odeslané is unreadable, so the '
          'send could not be verified (${e.runtimeType}: $e).');
      return false;
    }

    log('Sending excuse: $summary');
    final stopwatch = Stopwatch()..start();
    late final HttpResponseData resp;
    try {
      final post = formBody(fields);
      resp = await session.sendOnce('POST', _formPath,
          headers: post.headers, body: post.body);
    } on CancelledError {
      // Raised by the cancel check before anything was sent.
      rethrow;
    } on UserError catch (e) {
      final neverLeft = isNeverSentCause(e.cause);
      lastSubmitUncertain = !neverLeft;
      final outcome = neverLeft
          ? 'nothing was sent.'
          : 'it may or may not have been sent; '
              'NOT treating it as sent, and NOT sending it again.';
      log('Excuse post failed (${e.cause.runtimeType}): $outcome');
      return false;
    }
    final location = resp.firstHeader('location') ?? '';
    if ({301, 302, 303, 307, 308}.contains(resp.statusCode) &&
        location.toLowerCase().contains('/login')) {
      loggedIn = session.loggedIn = false;
      log('Excuse not sent: the Bakaláři session had expired '
          '(the post landed on the login page).');
      return false;
    }
    log('Excuse posted (HTTP ${resp.statusCode}'
        '${location.isNotEmpty ? ' → $location' : ''}, '
        '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s), '
        'checking Komens → Odeslané…');

    lastSubmitUncertain = true;
    final wholeDay =
        isDays || startLesson == null || endLesson == null;
    late final bool confirmed;
    try {
      confirmed = await confirmedInOutbox(session, before,
          parseCzDate(dayStart)!, parseCzDate(dayEnd)!,
          startLesson, endLesson, wholeDay);
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Warning: could not check Komens → Odeslané after the post '
          '(${e.runtimeType}: $e) — the excuse may or may not have been '
          'sent; NOT sending it again.');
      return false;
    }
    if (confirmed) {
      lastSubmitUncertain = false;
      log('Excuse sent: it is in Komens → Odeslané.');
      return true;
    }
    log('Warning: the excuse is not in Komens → Odeslané after the post '
        '— it may or may not have been sent; NOT treating it as sent, '
        'and NOT sending it again.');
    return false;
  }
}
