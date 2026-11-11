import 'package:clock/clock.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';

import 'package:app/features/activity/activity_controller.dart';
import 'package:app/widgets/overlays.dart';

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
  try {
    return DateTime.parse('${run['at'] ?? ''}');
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
  if (message.trim() == 'refresh_finished_log' ||
      message.trim() == 'connection_ok') {
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
    final blocks = <Widget>[
      _hero(context, now),
      _stats(now),
      _historyCard(now),
      _logCard(context),
      _automationCard(context),
      _auditCard(now),
    ];
    return ListView(
      children: [
        ListTile(
          title: Text(Strings.get('activity_title')),
          subtitle: Text(updatedLabel),
        ),
        ...blocks,
      ],
    );
  }

  Widget _hero(BuildContext context, DateTime now) {
    final c = controller;
    final kind = c.statusKind();
    final sending = c.sendingLabel;
    String headline;
    if (kind == 'working') {
      headline = c.refreshRunning ? Strings.get('refreshing') : sending;
    } else if (kind == 'error') {
      headline = Strings.get('status_error');
    } else if (kind == 'ok') {
      headline = Strings.get('status_ok');
    } else {
      headline = Strings.get('status_idle');
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (kind == 'working')
                  const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 3)),
                Expanded(child: Text(headline)),
                if (c.refreshRunning)
                  TextButton(
                      onPressed: c.cancelRefresh,
                      child: Text(Strings.get('cancel_refresh')))
                else
                  FilledButton(
                    onPressed: sending.isNotEmpty
                        ? null
                        : () => c.startRefresh(),
                    child: Text(Strings.get('refresh_data')),
                  ),
              ],
            ),
            if (kind == 'working')
              const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _stats(DateTime now) {
    final c = controller;
    final last = c.runs.isEmpty ? null : c.runs.last;
    final total = c.runs.length;
    final good = c.runs.where((r) => r['ok'] == true).length;
    final weekAgo = now.subtract(const Duration(days: 7));
    final sent = audit
        .where((i) =>
            i['outcome'] == 'sent' &&
            (runTime({'at': i['ts']}) ?? DateTime(1970))
                .isAfter(weekAgo))
        .length;
    return Wrap(
      spacing: 8,
      children: [
        _tile(Strings.get('last_run'),
            last == null ? '—' : runWhen(last, now)),
        _tile(Strings.get('next_run'), c.nextRunLabel(now: now)),
        _tile(Strings.get('stat_success'),
            total == 0 ? '—' : '$good/$total'),
        _tile(Strings.get('stat_sent_week'), '$sent'),
      ],
    );
  }

  Widget _tile(String label, String value) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Text(label), Text(value)]),
        ),
      );

  Widget _historyCard(DateTime now) {
    final c = controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Strings.get('run_history')),
            if (c.runs.isEmpty) Text(Strings.get('no_runs_yet')),
            for (final run in c.runs.reversed.take(10))
              ListTile(
                title: Text(
                    '${run['scope'] ?? 'all'} · ${runWhen(run, now)}'),
                subtitle: (run['detail'] ?? '').toString().isEmpty
                    ? null
                    : Text('${run['detail']}'),
                trailing: Text(runKind(run)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logCard(BuildContext context) {
    final c = controller;
    final lines =
        c.logLines.length > 150 ? c.logLines.sublist(c.logLines.length - 150) : c.logLines;
    final errors = countLogErrors(lines);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(Strings.get('live_log'))),
                if (errors > 0)
                  Chip(label: Text(Strings.format('log_errors', {'n': errors}))),
                IconButton(
                  tooltip: Strings.get('log_copy_tooltip'),
                  icon: const Icon(Icons.content_copy_outlined),
                  onPressed: () async {
                    if (c.logLines.isEmpty) {
                      appSnack(context, Strings.get('no_log_yet'));
                      return;
                    }
                    final ok = await copyAppText(c.logLines.join('\n'));
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
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: c.clearLog,
                ),
              ],
            ),
            if (lines.isEmpty)
              Text(Strings.get('no_log_yet'))
            else
              Container(
                height: (64 + 19 * lines.length).clamp(64, 320).toDouble(),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView(
                  children: [
                    for (final line in lines) _logRow(line),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logRow(String line) {
    final (stamp, message) = splitLog(line);
    final tone = logTone(message);
    final color = tone == 'error'
        ? Colors.red
        : tone == 'warning'
            ? Colors.orange
            : tone == 'ok'
                ? Colors.green
                : Colors.grey;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 58,
            child: Text(stamp,
                style:
                    const TextStyle(fontFamily: 'Consolas', fontSize: 12))),
        Expanded(
            child: SelectableText(message,
                style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: color))),
      ],
    );
  }

  Widget _modeRow(String label, String key) {
    final c = controller;
    final mode = '${c.config[key] ?? 'confirm'}'.isEmpty
        ? 'confirm'
        : '${c.config[key] ?? 'confirm'}';
    final color = {'auto': Colors.green, 'dry_run': Colors.amber}[mode];
    final text = Strings.get(
        {'auto': 'mode_auto', 'dry_run': 'mode_dry_run'}[mode] ??
            'mode_confirm');
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ],
    );
  }

  /// The automation card: pause switch plus the current modes. Port of
  /// `_automation_card` (views/activity.py).
  Widget _automationCard(BuildContext context) {
    final c = controller;
    final paused = c.automationPaused();
    return Card(
      key: const Key('activity:automation'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.bolt_outlined, size: 18),
              const SizedBox(width: 8),
              Text(Strings.get('automation_card'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            if (paused)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.pause_circle_outline,
                      size: 18, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(Strings.get('automation_paused_banner'),
                        style: const TextStyle(
                            fontSize: 12,
                            color: Colors.amber,
                            fontWeight: FontWeight.bold)),
                  ),
                ]),
              )
            else
              Text(Strings.get('automation_running'),
                  style: const TextStyle(fontSize: 12)),
            SwitchListTile(
              key: const Key('activity:pause'),
              contentPadding: EdgeInsets.zero,
              title: Text(Strings.get('automation_pause')),
              value: paused,
              onChanged: c.setAutomationPaused,
            ),
            Text(Strings.get('automation_pause_hint'),
                style: const TextStyle(fontSize: 12)),
            const Divider(),
            _modeRow(Strings.get('excuse_mode_label'), 'excuse_mode'),
            _modeRow(Strings.get('order_mode_label'), 'strava_order_mode'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.tune),
                label: Text(Strings.get('automation_edit')),
                onPressed: c.editRules,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _auditCard(DateTime now) {
    final groups = groupAudit(audit);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Strings.get('automation_history')),
            if (auditError.isNotEmpty) Text(auditError),
            if (groups.isEmpty && auditError.isEmpty)
              Text(Strings.get('automation_history_empty')),
            for (final g in groups.take(12))
              ListTile(
                title: Text(auditRowTitle(g)),
                subtitle: Text(auditRowSubs(g, foodNames).join(' · ')),
                trailing: Text(Strings.get('audit_${g.first['outcome'] ?? 'failed'}')),
              ),
          ],
        ),
      ),
    );
  }
}
