import 'package:clock/clock.dart';
import 'package:app/l10n/strings.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;
import 'package:flutter/material.dart';

import 'package:app/features/activity/activity_controller.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/common/open_url.dart' as open_url;
import 'package:app/widgets/app_widgets.dart' as w;
import 'package:app/widgets/overlays.dart';

/// Log tail with known secret values scrubbed: the only form logs may be
/// copied in. Port of `activity.redacted_log_tail`.
String redactedLogTail(ActivityController c, [int limit = 200]) {
  final lines = c.logLines.length > limit
      ? c.logLines.sublist(c.logLines.length - limit)
      : c.logLines;
  return [for (final line in lines) core.redactText(line, c.config)].join('\n');
}

/// Time helpers (port of activity._ago/_clock/_duration/_run_when).
String agoText(DateTime? when, DateTime now) {
  if (when == null) return '—';
  final secs = now.difference(when).inSeconds;
  if (secs < 60) return Strings.get('ago_now');
  if (secs < 3600) return Strings.format('ago_min', {'n': secs ~/ 60});
  if (secs < 6 * 3600) return Strings.format('ago_hours', {'n': secs ~/ 3600});
  final hm =
      '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
  if (when.year == now.year &&
      when.month == now.month &&
      when.day == now.day) {
    return hm;
  }
  return '${when.day}. ${when.month}. $hm';
}

String durationText(Object? seconds) {
  int total;
  try {
    total = (seconds as num).toInt();
  } catch (_) {
    return '';
  }
  if (total < 0) total = 0;
  if (total < 60) return '$total s';
  return '${total ~/ 60} min ${total % 60} s';
}

DateTime? runTime(Map<String, dynamic> run) {
  final raw = '${run['at'] ?? ''}'.trim();
  // Legacy runs stored a date-only YYYY-MM-DD 'at'; skip midnight parsing so
  // runWhen falls back to the preformatted 'finished' clock label instead.
  if (!raw.contains('T') && !raw.contains(' ')) return null;
  try {
    return DateTime.parse(raw);
  } catch (_) {
    return null;
  }
}

String runWhen(Map<String, dynamic> run, DateTime now) {
  final at = runTime(run);
  return at != null ? agoText(at, now) : '${run['finished'] ?? '—'}';
}

String runKind(Map<String, dynamic> run) {
  if (run['ok'] == true) return 'ok';
  return run['cancelled'] == true ? 'cancelled' : 'failed';
}

/// Splits '[10:00:05] text' → ('10:00:05', 'text').
/// Port of activity._split_log.
(String, String) splitLog(String line) {
  final m = RegExp(r'^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s?(.*)$',
          dotAll: true)
      .firstMatch(line);
  if (m == null) return ('', line);
  return (m.group(1)!, m.group(2)!);
}

final _logError =
    RegExp(r'traceback|error|exception|failed|selhal|chyba|^\s*File "', caseSensitive: false);
final _logWarn =
    RegExp(r'warning|varování|cancel|zrušen', caseSensitive: false);

/// error | warning | ok | '' — drives the line color.
String logTone(String message) {
  final text = message.trim();
  if (text == 'refresh_finished_log' ||
      text == 'connection_ok' ||
      text == Strings.get('refresh_finished_log') ||
      text == Strings.get('connection_ok')) {
    return 'ok';
  }
  if (_logError.hasMatch(message)) return 'error';
  if (_logWarn.hasMatch(message)) return 'warning';
  return '';
}

/// Counts runs of consecutive error lines as one error each.
int countLogErrors(List<String> lines) {
  final tones = [for (final l in lines) logTone(splitLog(l).$2)];
  var n = 0;
  for (var i = 0; i < tones.length; i++) {
    if (tones[i] == 'error' && (i == 0 || tones[i - 1] != 'error')) {
      n++;
    }
  }
  return n;
}

/// Consecutive records of one batch → one group. Port of _group_audit.
List<List<Map<String, dynamic>>> groupAudit(
    List<Map<String, dynamic>> items) {
  final groups = <List<Map<String, dynamic>>>[];
  for (final item in items) {
    final detail =
        item['detail'] is Map ? item['detail'] as Map : const {};
    final key = (
      '${item['ts'] ?? ''}'.length >= 16
          ? '${item['ts'] ?? ''}'.substring(0, 16)
          : '${item['ts'] ?? ''}',
      item['kind'],
      item['outcome'],
      item['source'],
      detail['reason'],
      '${detail['meal'] ?? ''}'.contains('&-1&'),
    );
    if (groups.isNotEmpty && groups.last.first['_key'] == key) {
      groups.last.add({...item, '_key': key});
    } else {
      groups.add([
        {...item, '_key': key}
      ]);
    }
  }
  return groups;
}

String _czDay(DateTime d) => '${d.day}. ${d.month}.';

/// One audit row title (translated, never the core's English).
/// Returns the full title line for tests.
String auditRowTitle(List<Map<String, dynamic>> group) {
  final first = group.first;
  final kind = '${first['kind'] ?? 'excuse'}';
  final detail =
      first['detail'] is Map ? first['detail'] as Map : const {};
  var title = Strings.get('audit_kind_$kind');
  if (kind == 'lunch') {
    final action = '${detail['meal'] ?? ''}'.contains('&-1&')
        ? Strings.get('audit_lunch_cancel')
        : Strings.get('audit_lunch_order');
    title = '$title · $action';
  }
  if (group.length > 1) title = '$title ×${group.length}';
  return title;
}

/// One audit row subtitle.
List<String> auditRowSubs(
    List<Map<String, dynamic>> group, Map<String, String> foodNames) {
  final first = group.first;
  final kind = '${first['kind'] ?? 'excuse'}';
  final detail =
      first['detail'] is Map ? first['detail'] as Map : const {};
  final subs = <String>[];
  if (kind == 'lunch') {
    final days = [
      for (final g in group)
        '${(g['detail'] is Map ? g['detail'] : const {})['day'] ?? ''}'
    ];
    if (group.length == 1 && days.first.isNotEmpty) {
      final mealName = foodNames['${detail['meal']}'] ?? '';
      subs.add(
          [days.first, mealName].where((p) => p.isNotEmpty).join(' · '));
    } else {
      subs.add(_daysLabel(days));
    }
    if (detail['reason'] == 'low_balance') {
      subs.add(Strings.get('audit_reason_low_balance'));
    } else if (detail['reason'] == 'free_day') {
      subs.add(Strings.get('audit_reason_free_day'));
    } else if (detail['reason'] == 'planned') {
      subs.add(Strings.get('audit_reason_planned'));
    }
  } else {
    final summaries = [
      for (final g in group) _czDates('${g['summary'] ?? ''}')
    ];
    subs.add(summaries.take(3).join(', ') +
        (summaries.length > 3 ? ' +${summaries.length - 3}' : ''));
  }
  return subs;
}

String _czDates(String text) {
  // '18.09.2026' → '18. 9. 2026' (no zero padding, like C.cz_day_year).
  return text.replaceAllMapped(
    RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})'),
    (m) =>
        '${int.parse(m.group(1)!)}. ${int.parse(m.group(2)!)}. ${m.group(3)}',
  );
}

String _daysLabel(List<String> days, [int limit = 4]) {
  final parsed = <DateTime>{};
  for (final d in days) {
    final m =
        RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(d);
    if (m == null) continue;
    try {
      parsed.add(DateTime(int.parse(m.group(3)!),
          int.parse(m.group(2)!), int.parse(m.group(1)!)));
    } catch (_) {}
  }
  if (parsed.isEmpty) return '';
  final sorted = parsed.toList()..sort();
  final shown = sorted.take(limit).map(_czDay).join(', ');
  return sorted.length > limit
      ? '$shown +${sorted.length - limit}'
      : shown;
}

/// Width from which the two columns sit side by side (Python `WIDE_MIN_WIDTH`).
const double activityWideMinWidth = 1120;
const double _panelWidth = 380;
const double _logHeight = 320;
const int _historyRows = 10;
const int _auditGroups = 12;

const _auditBadge = {
  'sent': 'sent',
  'dry_run': 'pending',
  'covered': 'ok',
  'skipped': 'warning',
  'unconfirmed': 'warning',
  'failed': 'failed',
};
const _scopes = [
  ('all', 'refresh_all'),
  ('bakalari', 'scope_bakalari'),
  ('strava', 'scope_strava'),
];

/// '14:30' today, '25. 9. 14:30' on other days (Python `_clock`).
String clockText(DateTime when, DateTime now) {
  final hm =
      '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
  final sameDay =
      when.year == now.year && when.month == now.month && when.day == now.day;
  return sameDay ? hm : '${when.day}. ${when.month}. $hm';
}

/// Aktivita: status hero, stat tiles, run timeline, live log,
/// automation card and automation history. Port of views/activity.py.
class ActivityView extends StatelessWidget {
  final ActivityController controller;
  final List<Map<String, dynamic>> audit;
  final String auditError;
  final bool narrow;
  final String updatedLabel;
  final String appVersion;
  final Map<String, String> foodNames;
  final DateTime Function()? nowFor;
  final Future<String?> Function(String url)? openUrl;

  const ActivityView({
    super.key,
    required this.controller,
    this.audit = const [],
    this.auditError = '',
    this.narrow = false,
    this.updatedLabel = '',
    this.appVersion = '',
    this.foodNames = const {},
    this.nowFor,
    this.openUrl,
  });

  @override
  Widget build(BuildContext context) {
    final now = nowFor?.call() ?? clock.now();
    final tok = tokensOf(context);
    final c = controller;
    final wide = MediaQuery.sizeOf(context).width >= activityWideMinWidth;
    final blocks = <Widget>[
      w.HeaderRow(
        heading: Strings.get('activity_title'),
        updated: updatedLabel,
        tok: tok,
        actions: [
          if (appVersion.isNotEmpty)
            Text('${Strings.get('app_version')} $appVersion',
                style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
          IconButton(
            iconSize: 18,
            color: tok.muted,
            tooltip: c.updateCheckRunning
                ? Strings.get('checking_updates')
                : Strings.get('check_updates'),
            icon: const Icon(Icons.system_update_alt),
            onPressed: c.updateCheckRunning
                ? null
                : () => c.startUpdateCheck(force: true),
          ),
        ],
      ),
      ?_updateBanner(context, tok),
      _hero(context, tok, now, wide),
      _stats(tok, now),
    ];
    final history = _historyCard(tok, now);
    final log = _logCard(context, tok);
    final automation = _automationCard(context, tok);
    final auditCard = _auditCard(tok, now);
    Widget stack(List<Widget> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tok.gap,
          children: items,
        );
    if (wide) {
      blocks.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tok.gap,
        children: [
          Expanded(child: stack([history, log])),
          SizedBox(width: _panelWidth, child: stack([automation, auditCard])),
        ],
      ));
    } else {
      blocks.addAll([history, automation, auditCard, log]);
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          blocks[i],
          if (i != blocks.length - 1) SizedBox(height: tok.gap),
        ],
        SizedBox(height: tok.pad * 2),
      ],
    );
  }

  // -- small pieces ------------------------------------------------------------

  Widget _iconDisc(IconData icon, Color color, Tokens tok,
      {double size = 32, double iconSize = 18}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tintColor(color, 0.14),
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Icon(icon, size: iconSize, color: color),
    );
  }

  Widget _panelHead(String title, Tokens tok, IconData icon,
      [List<Widget> extra = const []]) {
    return Row(
      spacing: 6,
      children: [
        Icon(icon, size: 16, color: tok.faint),
        w.SectionHeader(title, tok: tok),
        ...extra,
      ],
    );
  }

  Widget _small(Tokens tok, String text,
      {Color? color, bool bold = false, double? size}) {
    return Text(text,
        style: TextStyle(
            color: color ?? tok.muted,
            fontSize: size ?? tok.fsSmall,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400));
  }

  // -- update banner -------------------------------------------------------------

  Widget? _updateBanner(BuildContext context, Tokens tok) {
    final info = controller.updateBanner;
    if (info == null) return null;
    final latest = '${info['version'] ?? '?'}';
    final desc = Strings.format('update_desc',
        {'cur': appVersion.isEmpty ? '?' : appVersion, 'v': latest});
    final lead = <Widget>[
      Icon(Icons.new_releases_outlined, color: tok.accent, size: 22),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(Strings.format('update_available', {'v': latest}),
                style: TextStyle(
                    color: tok.text,
                    fontSize: tok.fsBody,
                    fontWeight: FontWeight.w700)),
            _small(tok, desc),
          ],
        ),
      ),
    ];
    final buttons = <Widget>[
      ElevatedButton.icon(
        onPressed: () {
          final url = '${info['url'] ?? ''}';
          if (url.isEmpty) return;
          final seam = openUrl;
          if (seam != null) {
            seam(url);
          } else {
            open_url.openUrl(url);
          }
        },
        icon: const Icon(Icons.download, size: 18),
        label: Text(Strings.get('download_update')),
      ),
      OutlinedButton(
        onPressed: controller.dismissUpdate,
        child: Text(Strings.get('update_dismiss')),
      ),
    ];
    final Widget content = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              Row(
                  spacing: 10,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: lead),
              Wrap(spacing: 8, runSpacing: 8, children: buttons),
            ],
          )
        : Row(
            spacing: 10,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [...lead, ...buttons]);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: tok.pad, vertical: 10),
      decoration: BoxDecoration(
        color: tintColor(tok.accent, 0.10),
        borderRadius: BorderRadius.circular(tok.radiusMd),
        border: Border.all(color: tintColor(tok.accent, 0.5)),
      ),
      child: content,
    );
  }

  // -- status hero -----------------------------------------------------------------

  Widget _hero(BuildContext context, Tokens tok, DateTime now, bool wide) {
    final c = controller;
    final last = c.runs.isEmpty ? null : c.runs.last;
    final lastAt = last == null ? null : runTime(last);
    final quickAt = c.lastQuickCheck;
    final quickIsNewest = quickAt != null &&
        (last == null || (lastAt != null && quickAt.isAfter(lastAt)));
    final baseKind = c.statusKind();
    final kind = (baseKind == 'idle' && quickIsNewest) ? 'ok' : baseKind;
    final sending =
        c.sendingLabel.isEmpty ? '' : Strings.get(c.sendingLabel);
    final lines = <Widget>[];
    final String headline;
    final Color color;
    final Widget disc;
    if (kind == 'working') {
      headline = c.refreshRunning ? Strings.get('refreshing') : sending;
      color = tok.accent;
      disc = Container(
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: tintColor(color, 0.14),
            borderRadius: BorderRadius.circular(26)),
        child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 3, color: color)),
      );
      if (c.refreshRunning && c.currentStep.isNotEmpty) {
        lines.add(_small(tok, c.currentStep));
      }
      lines.add(_small(tok, Strings.get('activity_working_hint'),
          color: tok.faint));
    } else if (kind == 'error') {
      headline = Strings.get('status_error');
      color = tok.red;
      disc = _iconDisc(Icons.error_outline_rounded, color, tok,
          size: 52, iconSize: 28);
      if (last != null && last['ok'] != true) {
        final key = last['cancelled'] == true
            ? 'activity_last_cancelled'
            : 'activity_last_failed';
        lines.add(
            _small(tok, Strings.format(key, {'when': runWhen(last, now)})));
      }
      var detail = '${(last ?? const {})['detail'] ?? ''}';
      if (detail.isEmpty && c.lastError != null) {
        detail = '${c.lastError!['summary'] ?? ''}';
      }
      if (detail.isNotEmpty) lines.add(_small(tok, detail, color: tok.red));
    } else if (kind == 'ok') {
      headline = Strings.get('status_ok');
      color = tok.green;
      disc = _iconDisc(Icons.check_circle_outline_rounded, color, tok,
          size: 52, iconSize: 28);
      final whenText = quickIsNewest
          ? clockText(quickAt, now)
          : runWhen(last ?? const {}, now);
      lines.add(
          _small(tok, Strings.format('activity_last_ok', {'when': whenText})));
      if (!quickIsNewest) {
        final detail = '${(last ?? const {})['detail'] ?? ''}';
        if (detail.isNotEmpty) lines.add(_small(tok, detail, color: tok.faint));
      }
    } else {
      headline = Strings.get('status_idle');
      color = tok.muted;
      disc = _iconDisc(Icons.schedule_rounded, color, tok,
          size: 52, iconSize: 28);
      if (last != null && last['cancelled'] == true) {
        lines.add(_small(
            tok,
            Strings.format(
                'activity_last_cancelled', {'when': runWhen(last, now)})));
      } else {
        lines.add(_small(tok, Strings.get('no_runs_yet')));
      }
    }
    if (kind == 'error' && c.errorReportText().isNotEmpty) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => showErrorDialog(
              context,
              title: Strings.get('error_title'),
              summary: '${c.lastError?['summary'] ?? ''}',
              reportText: c.errorReportText(),
              userMessage: '${c.lastError?['user_message'] ?? ''}',
            ),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: Text(Strings.get('error_details')),
          ),
        ),
      ));
    }
    final titleRow = <Widget>[
      Text(headline,
          style: TextStyle(
              color: tok.text,
              fontSize: tok.fsTitle,
              fontWeight: FontWeight.w700)),
      if (c.automationPaused())
        w.Badge(
            text: Strings.get('automation_paused_banner'),
            tok: tok,
            kind: 'warning'),
    ];
    final actions = <Widget>[];
    if (c.refreshRunning) {
      actions.add(OutlinedButton.icon(
        onPressed: c.cancelRefresh,
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: Text(Strings.get('cancel_refresh')),
      ));
    } else {
      final scope = c.draft('activity:scope', 'all');
      actions.add(Tooltip(
        message: Strings.get('refresh_scope'),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final (key, label) in _scopes)
              ButtonSegment(value: key, label: Text(Strings.get(label))),
          ],
          selected: {_scopes.any((s) => s.$1 == scope) ? scope : 'all'},
          onSelectionChanged: (v) =>
              c.setDraft('activity:scope', v.isEmpty ? 'all' : v.first),
        ),
      ));
      actions.add(ElevatedButton.icon(
        onPressed: sending.isNotEmpty
            ? null
            : () {
                if (!c.startRefresh(c.draft('activity:scope', 'all'))) {
                  appSnack(context, Strings.get('already_running'));
                }
              },
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(Strings.get('refresh_data')),
      ));
    }
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 3,
      children: [
        Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: titleRow),
        ...lines,
      ],
    );
    final Widget wideActions = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: actions);
    final Widget narrowActions = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: actions);
    return Container(
      padding: EdgeInsets.all(tok.pad),
      decoration: BoxDecoration(
        color: tintColor(color, 0.07),
        borderRadius: BorderRadius.circular(tok.radiusMd),
        border: Border.all(color: tintColor(color, 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            spacing: 14,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [disc, Expanded(child: text), if (wide) wideActions],
          ),
          if (!wide) narrowActions,
          if (kind == 'working')
            LinearProgressIndicator(color: tok.accent, backgroundColor: tok.overlay),
        ],
      ),
    );
  }

  // -- stat tiles ------------------------------------------------------------------

  Widget _stats(Tokens tok, DateTime now) {
    final c = controller;
    final last = c.runs.isEmpty ? null : c.runs.last;
    final lastAt = last == null ? null : runTime(last);
    final quickAt = c.lastQuickCheck;
    final quickIsNewest = quickAt != null &&
        (last == null || (lastAt != null && quickAt.isAfter(lastAt)));
    var lastValue = '—';
    var lastKind = 'info';
    if (quickIsNewest) {
      lastValue = clockText(quickAt, now);
      lastKind = 'ok';
    } else if (last != null) {
      lastValue = runWhen(last, now);
      lastKind = const {'ok': 'ok', 'cancelled': 'cancelled'}[runKind(last)] ??
          'failed';
    }
    final total = c.runs.length;
    final good = c.runs.where((r) => r['ok'] == true).length;
    var success = '—';
    var successKind = 'info';
    if (total > 0) {
      success = '$good/$total';
      successKind = good == total ? 'ok' : (good > 0 ? 'warning' : 'failed');
    }
    final weekAgo = core.addDays(now, -7);
    final sent = audit
        .where((i) =>
            i['outcome'] == 'sent' &&
            (runTime({'at': i['ts']}) ?? DateTime(1970)).isAfter(weekAgo))
        .length;
    final cards = <Widget>[
      w.StatCard(
          label: Strings.get('last_run'),
          value: lastValue,
          tok: tok,
          kind: lastKind),
      w.StatCard(
          label: Strings.get('next_run'),
          value: c.nextRunLabel(now: now),
          tok: tok),
      w.StatCard(
          label: Strings.get('stat_success'),
          value: success,
          tok: tok,
          kind: successKind),
      w.StatCard(
          label: Strings.get('stat_sent_week'),
          value: '$sent',
          tok: tok,
          kind: sent > 0 ? 'ok' : 'info'),
    ];
    if (!narrow) {
      return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: tok.gap,
          children: cards);
    }
    final half = tok.gap / 2;
    return Column(spacing: half, children: [
      for (var i = 0; i < cards.length; i += 2)
        Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: half,
            children: cards.sublist(i, i + 2)),
    ]);
  }

  // -- run timeline ------------------------------------------------------------------

  String _scopeLabel(String scope) {
    if (scope == 'quick') return Strings.get('scope_quick');
    for (final (key, label) in _scopes) {
      if (key == scope) return Strings.get(label);
    }
    return Strings.get('refresh_all');
  }

  Widget _historyCard(Tokens tok, DateTime now) {
    final c = controller;
    final hasQuick = c.quickChecksToday > 0 && c.lastQuickCheck != null;
    final rows = <Widget>[
      _panelHead(Strings.get('run_history'), tok, Icons.history),
      if (hasQuick)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Text(
            Strings.format('activity_quick_checks', {
              'n': c.quickChecksToday,
              'time': clockText(c.lastQuickCheck!, now),
            }),
            key: const ValueKey('activity:quick_checks'),
            style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
          ),
        ),
      if (c.runs.isEmpty && !hasQuick)
        Text(Strings.get('no_runs_yet'),
            style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
    ];
    for (final run in c.runs.reversed.take(_historyRows)) {
      final kind = runKind(run);
      final (icon, color, label, badgeKind) = switch (kind) {
        'ok' => (Icons.check_rounded, tok.green, Strings.get('run_done'), 'sent'),
        'cancelled' => (
            Icons.block_rounded,
            tok.muted,
            Strings.get('run_cancelled'),
            'cancelled'
          ),
        _ => (Icons.close_rounded, tok.red, Strings.get('run_failed'), 'failed'),
      };
      final meta = <String>[_scopeLabel('${run['scope'] ?? 'all'}')];
      final took =
          run['seconds'] != null ? durationText(run['seconds']) : '';
      if (took.isNotEmpty) {
        meta.add(Strings.format('run_took', {'d': took}));
      }
      final detail = '${run['detail'] ?? ''}';
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          spacing: 10,
          children: [
            _iconDisc(icon, color, tok, size: 28, iconSize: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 1,
                children: [
                  _small(tok, meta.join(' · '), color: tok.text, bold: true),
                  if (detail.isNotEmpty)
                    _small(tok, detail,
                        size: tok.fsTiny,
                        color: badgeKind == 'failed' ? tok.red : tok.muted),
                ],
              ),
            ),
            _small(tok, runWhen(run, now), size: tok.fsTiny, color: tok.faint),
            w.Badge(text: label, tok: tok, kind: badgeKind),
          ],
        ),
      ));
    }
    return w.AppCard(tok: tok, children: rows);
  }

  // -- live log ----------------------------------------------------------------------

  Widget _logCard(BuildContext context, Tokens tok) {
    final c = controller;
    final lines = c.logLines.length > 150
        ? c.logLines.sublist(c.logLines.length - 150)
        : c.logLines;
    final errors = countLogErrors(lines);
    final head = _panelHead(Strings.get('live_log'), tok, Icons.terminal, [
      if (errors > 0)
        w.Badge(
            text: Strings.format('log_errors', {'n': errors}),
            tok: tok,
            kind: 'failed'),
      const Spacer(),
      IconButton(
        tooltip: Strings.get('log_copy_tooltip'),
        iconSize: 18,
        color: tok.muted,
        icon: const Icon(Icons.content_copy_outlined),
        onPressed: () async {
          if (c.logLines.isEmpty) {
            appSnack(context, Strings.get('no_log_yet'));
            return;
          }
          String body;
          try {
            body = redactedLogTail(c);
          } catch (_) {
            // Fail closed: never fall back to copying raw logs that may
            // still hold secrets.
            appSnack(context, Strings.get('error_copy_failed'));
            return;
          }
          final ok = await copyAppText(body);
          if (context.mounted) {
            appSnack(
                context,
                ok
                    ? Strings.get('error_copied')
                    : Strings.get('error_copy_failed'));
          }
        },
      ),
      IconButton(
        tooltip: Strings.get('clear_log'),
        iconSize: 18,
        color: tok.muted,
        icon: const Icon(Icons.delete_sweep_outlined),
        onPressed: c.clearLog,
      ),
    ]);
    final Widget screen = lines.isEmpty
        ? Center(
            child: Text(Strings.get('no_log_yet'),
                style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)))
        : ListView(
            reverse: false,
            children: [
              for (final line in lines) ...[
                _logRow(tok, line),
                const SizedBox(height: 2),
              ],
            ],
          );
    final height = (18 + 19 * lines.length).clamp(64, _logHeight).toDouble();
    return w.AppCard(tok: tok, children: [
      head,
      Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: tok.surface,
          borderRadius: BorderRadius.circular(tok.radiusSm),
          border: Border.all(color: tok.border),
        ),
        child: screen,
      ),
    ]);
  }

  Widget _logRow(Tokens tok, String line) {
    final (stamp, message) = splitLog(line);
    final tone = logTone(message);
    final color = switch (tone) {
      'error' => tok.red,
      'warning' => tok.yellow,
      'ok' => tok.green,
      _ => tok.muted,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        SizedBox(
            width: 58,
            child: Text(stamp,
                style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: tok.fsTiny,
                    color: tok.faint))),
        Expanded(
            child: SelectableText(message,
                style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: tok.fsSmall,
                    color: color))),
      ],
    );
  }

  // -- automation (right panel) ----------------------------------------------------------

  Widget _modeRow(Tokens tok, String label, String key) {
    final c = controller;
    var mode = '${c.config[key] ?? 'confirm'}';
    if (mode.isEmpty) mode = 'confirm';
    final color = switch (mode) {
      'auto' => tok.green,
      'dry_run' => tok.yellow,
      _ => tok.text,
    };
    final text = Strings.get(
        {'auto': 'mode_auto', 'dry_run': 'mode_dry_run'}[mode] ??
            'mode_confirm');
    return Row(
      spacing: 8,
      children: [
        Expanded(child: _small(tok, label)),
        _small(tok, text, color: color, bold: true),
      ],
    );
  }

  /// The automation card: pause switch plus the current modes. Port of
  /// `_automation_card` (views/activity.py).
  Widget _automationCard(BuildContext context, Tokens tok) {
    final c = controller;
    final paused = c.automationPaused();
    return KeyedSubtree(
      key: const Key('activity:automation'),
      child: w.AppCard(tok: tok, children: [
        _panelHead(Strings.get('automation_card'), tok, Icons.bolt_outlined),
        if (paused)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tintColor(tok.yellow, 0.12),
              borderRadius: BorderRadius.circular(tok.radiusSm),
            ),
            child: Row(spacing: 8, children: [
              Icon(Icons.pause_circle_outline, size: 18, color: tok.yellow),
              Expanded(
                child: _small(tok, Strings.get('automation_paused_banner'),
                    color: tok.yellow, bold: true),
              ),
            ]),
          )
        else
          _small(tok, Strings.get('automation_running')),
        Row(spacing: 4, children: [
          Switch(
            key: const Key('activity:pause'),
            value: paused,
            onChanged: c.setAutomationPaused,
          ),
          Expanded(
            child: Text(Strings.get('automation_pause'),
                style: TextStyle(color: tok.text, fontSize: tok.fsBody)),
          ),
        ]),
        Text(Strings.get('automation_pause_hint'),
            style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
        Divider(color: tok.border, height: 1, thickness: 1),
        _modeRow(tok, Strings.get('excuse_mode_label'), 'excuse_mode'),
        _modeRow(tok, Strings.get('order_mode_label'), 'strava_order_mode'),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.tune, size: 18),
            label: Text(Strings.get('automation_edit')),
            onPressed: c.editRules,
          ),
        ),
      ]),
    );
  }

  Widget _auditRow(Tokens tok, List<Map<String, dynamic>> group, DateTime now) {
    final first = group.first;
    final kind = '${first['kind'] ?? 'excuse'}';
    final outcome = '${first['outcome'] ?? 'failed'}';
    final badgeKind = _auditBadge[outcome] ?? 'failed';
    final color = statusColor(badgeKind, tok);
    final subs = auditRowSubs(group, foodNames);
    final when = runTime({'at': first['ts']});
    final source = '${first['source'] ?? 'manual'}';
    final meta = [
      if (when != null) clockText(when, now),
      Strings.get('audit_source_$source'),
    ].where((p) => p.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        spacing: 10,
        children: [
          _iconDisc(
              kind == 'lunch'
                  ? Icons.restaurant_outlined
                  : Icons.description_outlined,
              color,
              tok,
              size: 30,
              iconSize: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: [
                _small(tok, auditRowTitle(group), color: tok.text, bold: true),
                for (final p in subs)
                  if (p.isNotEmpty) _small(tok, p, size: tok.fsTiny),
                _small(tok, meta, size: tok.fsTiny, color: tok.faint),
              ],
            ),
          ),
          w.Badge(
              text: Strings.get('audit_$outcome'), tok: tok, kind: badgeKind),
        ],
      ),
    );
  }

  Widget _auditCard(Tokens tok, DateTime now) {
    final c = controller;
    final wanted = c.draft('activity:audit', 'all');
    var items = audit;
    if (wanted == 'excuse' || wanted == 'lunch') {
      items = [
        for (final i in audit)
          if (i['kind'] == wanted) i
      ];
    }
    final groups = groupAudit(items);
    return w.AppCard(tok: tok, children: [
      _panelHead(Strings.get('automation_history'), tok,
          Icons.fact_check_outlined),
      SegmentedButton<String>(
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        segments: [
          ButtonSegment(
              value: 'all', label: Text(Strings.get('audit_filter_all'))),
          ButtonSegment(
              value: 'excuse',
              label: Text(Strings.get('audit_filter_excuse'))),
          ButtonSegment(
              value: 'lunch', label: Text(Strings.get('audit_filter_lunch'))),
        ],
        selected: {
          const ['all', 'excuse', 'lunch'].contains(wanted) ? wanted : 'all'
        },
        onSelectionChanged: (v) =>
            c.setDraft('activity:audit', v.isEmpty ? 'all' : v.first),
      ),
      if (auditError.isNotEmpty)
        _small(tok, '${Strings.get('automation_history')}: $auditError',
            color: tok.red),
      if (groups.isEmpty && auditError.isEmpty)
        Text(Strings.get('automation_history_empty'),
            style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
      for (final g in groups.take(_auditGroups)) _auditRow(tok, g, now),
    ]);
  }
}
