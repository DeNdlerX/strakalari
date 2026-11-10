import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../common/app_tokens.dart';
import '../common/format.dart';
import 'today_controller.dart';

/// Today (Dnes) home screen — port of `views/today.py`.
///
/// Renders from [TodayController]: the setup card (demo mode), pending
/// excuse cards (grouped day cards + single-lesson cards + ignored
/// block), the clock-aware next-lesson card, week changes + notes,
/// lunch and the planner tip. Stateless; state changes flow through
/// the controller via [ListenableBuilder].
class TodayView extends StatelessWidget {
  final TodayController controller;
  final AppTokens tokens;

  /// Phone layout: sections stack full-width (same column, roomier).
  final bool narrow;

  /// Fixed clock for tests/screenshots (defaults to `DateTime.now()`).
  final DateTime? now;

  const TodayView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context, now ?? DateTime.now()),
    );
  }

  Widget _body(BuildContext context, DateTime now) {
    final c = controller;
    final t = tokens;
final blocks = <Widget>[
      _headerRow(Strings.get('today_title'), c.updatedLabel),
    ];
    if (c.demoMode) {
      blocks.add(_demoCard(context));
    }
    blocks.addAll(_excuseCards(context, now));
    blocks.add(_sectionHeader(Strings.get('next_lesson')));
    blocks.add(_nextLessonCard(now));
    final changes = c.weekChanges(now);
    blocks.add(_sectionHeader(
        '${Strings.get('week_changes')} (${changes.changes.length})'));
    if (changes.changes.isEmpty) {
      blocks.add(_card(Text(
          demoModeText(),
          style: TextStyle(color: t.faint, fontSize: t.fsBody))));
    }
    for (final item in changes.changes) {
      blocks.add(_changeCard(item.title, item.note));
    }
    if (changes.notes.isNotEmpty) {
      blocks.add(_sectionHeader(
          '${Strings.get('notes_title')} (${changes.notes.length})'));
      for (final item in changes.notes) {
        blocks.add(_noteCard(item.title));
      }
    }
    blocks.add(_sectionHeader(Strings.get('lunch_today')));
    blocks.add(_card(Text(c.lunchText(now),
        style: TextStyle(color: t.text, fontSize: t.fsBody))));
    final tip = c.plannerTip(now);
    if (tip != null) {
      blocks.add(_sectionHeader(Strings.get('planner_suggestion')));
      blocks.add(_card(Row(
        children: [
          Icon(Icons.beach_access_outlined, color: t.green, size: 20),
          const SizedBox(width: 12),
          Expanded(
              child: Text(tip,
                  style: TextStyle(
                      color: t.text,
                      fontSize: t.fsBody,
                      fontWeight: FontWeight.bold))),
          TextButton(
            onPressed: () => c.onGo('planner'),
            child: Text(Strings.get('nav_planner')),
          ),
        ],
      )));
    }
    blocks.add(const SizedBox(height: 24));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          blocks[i],
          if (i != blocks.length - 1) SizedBox(height: t.gap),
        ],
      ],
    );
  }

  String demoModeText() {
    final c = controller;
    return c.demoMode ? Strings.get('no_data') : Strings.get('no_changes');
  }

  Widget _demoCard(BuildContext context) {
    final c = controller;
    final t = tokens;
return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(Strings.get('setup_needed'),
            style: TextStyle(color: t.muted, fontSize: t.fsBody)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: () {
                if (!c.onRefreshRequest()) {
                  _snack(context, Strings.get('already_running'));
                }
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(Strings.get('refresh_data')),
            ),
            TextButton(
              onPressed: () => c.onGo('settings'),
              child: Text(Strings.get('go_to_settings')),
            ),
          ],
        ),
      ],
    ));
  }

  List<Widget> _excuseCards(BuildContext context, DateTime now) {
    final c = controller;
    final t = tokens;
final grouped = c.groupedTasks(today: now);
    final out = <Widget>[
      _sectionHeader(
          '${Strings.get('pending_excuses')} (${c.excuseTasks(today: now).length})'),
    ];
    if (grouped.byDay.isEmpty && grouped.overflow == 0) {
      out.add(_card(Text(
          c.demoMode ? Strings.get('no_data') : Strings.get('no_changes'),
          style: TextStyle(color: t.faint, fontSize: t.fsBody))));
      out.addAll(_ignoredBlocks(context));
      return out;
    }
    if (grouped.overflow > 0) {
      out.add(_faint(
          '+ ${grouped.overflow} ${Strings.get('more_tasks')}'));
    }
    final sortedDays = grouped.byDay.keys.toList()..sort();
    for (final dayIso in sortedDays) {
      final dayTasks = grouped.byDay[dayIso]!;
      if (dayTasks.length > 1) {
        out.add(_dayGroupCard(context, dayIso, dayTasks));
      } else {
        out.add(_lessonCard(context, dayTasks.first));
      }
    }
    out.addAll(_ignoredBlocks(context));
    return out;
  }

  Widget _dayGroupCard(
      BuildContext context, String dayIso, List<ExcuseTask> dayTasks) {
    final c = controller;
    final t = tokens;
final day = parseCzDate(dayIso);
    final dayTitle = day == null
        ? dayIso
        : '${dayName(day, Strings.lang)} ${czDayYear(day)}';
    final wholeDay = c.dayFullyAbsent(dayIso,
        today: DateTime.now());
    final perLesson = c.excuseDayPerLesson;
    final dayKind = wholeDay && !perLesson ? 'day' : 'short';
    final options = c.templateOptions(dayKind);
    final key = 'day|$dayIso';
    final pickKey = perLesson ? '$key|each' : key;
    final subjects = dayTasks
        .map((task) {
          final parts = task.key.split('|');
          return parts.length == 3 ? parts[2] : '';
        })
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();
    final lessonsLabel = lessonsText(dayTasks.length);
    final summary = perLesson
        ? Strings.format('day_group_each',
            {'lessons': lessonsLabel, 'subjects': subjects.join(', ')})
        : Strings.format('day_group_covers',
            {'lessons': lessonsLabel, 'subjects': subjects.join(', ')});

    Future<void> sendDay() async {
      final request = c.dayRequest(dayIso, c.pickedOption(pickKey, options),
          perLesson: perLesson);
      if (request == null) {
        _snack(context, Strings.get('excuse_failed'));
        return;
      }
      if (c.signature.isEmpty) {
        _signatureDialog(context, request);
        return;
      }
      final ok = await c.send(request);
      if (context.mounted) {
        _snack(context,
            ok ? Strings.get('excuse_sent') : c.lastMessageOr(Strings.get('excuse_failed')));
      }
    }

    final sendLabel = perLesson
        ? Strings.format('excuse_lessons', {'lessons': lessonsLabel})
        : (wholeDay ? Strings.get('excuse_day') : Strings.get('excuse_all'));

    return _accentCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.event_busy_outlined, size: 20, color: t.accent),
            const SizedBox(width: 8),
            Expanded(
                child: Text(dayTitle,
                    style: TextStyle(
                        color: t.text,
                        fontSize: t.fsBody,
                        fontWeight: FontWeight.bold))),
            _kindBadge(dayKind == 'day' ? 'long' : 'short'),
          ],
        ),
        const SizedBox(height: 4),
        Text(summary,
            style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
        const SizedBox(height: 8),
        _templatePicker(context, pickKey, options),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton(
                onPressed: sendDay, child: Text(sendLabel)),
            TextButton(
              onPressed: () {
                final added = c.ignoreDay(dayIso);
                if (context.mounted) {
                  _snack(
                      context,
                      added.isNotEmpty
                          ? Strings.get('ignored_msg')
                          : c.lastMessageOr(Strings.get('save_failed')));
                }
              },
              child: Text(Strings.get('ignore_day')),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: perLesson,
                  activeThumbColor: t.accent,
                  onChanged: (v) {
                    if (!c.setExcuseDayPerLesson(v) && context.mounted) {
                      _snack(context, Strings.get('save_failed'));
                    }
                  },
                ),
                Flexible(
                  child: Text(Strings.get('excuse_each_lesson'),
                      style: TextStyle(
                          color: t.muted, fontSize: t.fsSmall)),
                ),
              ],
            ),
          ],
        ),
        Text(c.pickedOption(pickKey, options),
            style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
        _oneByOne(context, dayIso, dayTasks),
      ],
    ));
  }

  Widget _oneByOne(
      BuildContext context, String dayIso, List<ExcuseTask> dayTasks) {
    final c = controller;
    final t = tokens;
final expKey = 'excuse:$dayIso';
    return ExpansionTile(
      title: Text(
          Strings.format('or_one_by_one',
              {'n': lessonsText(dayTasks.length)}),
          style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
      initiallyExpanded: c.isDayExpanded(expKey),
      onExpansionChanged: (v) => c.setDayExpanded(expKey, v),
      tilePadding: EdgeInsets.zero,
      children: [for (final task in dayTasks) _lessonCard(context, task)],
    );
  }

  Widget _lessonCard(BuildContext context, ExcuseTask task) {
    final c = controller;
    final t = tokens;
final options = c.templateOptions(task.kind);
    final key = task.key;

    Future<void> send() async {
      final request =
          c.singleRequest(task, c.pickedOption(key, options));
      if (request == null) {
        _snack(context, Strings.get('excuse_failed'));
        return;
      }
      if (c.signature.isEmpty) {
        _signatureDialog(context, request);
        return;
      }
      final ok = await c.send(request);
      if (context.mounted) {
        _snack(context,
            ok ? Strings.get('excuse_sent') : c.lastMessageOr(Strings.get('excuse_failed')));
      }
    }

    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _kindBadge(task.kind),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.label,
                      style: TextStyle(
                          color: t.text,
                          fontSize: t.fsBody,
                          fontWeight: FontWeight.bold)),
                  if (task.detail.isNotEmpty)
                    Text(task.detail,
                        style: TextStyle(
                            color: t.muted, fontSize: t.fsSmall)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _templatePicker(context, key, options),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(onPressed: send, child: Text(Strings.get('excused_btn'))),
            TextButton(
              onPressed: () {
                final hidden = c.ignoreExcuse(task.key);
                if (context.mounted) {
                  _snack(
                      context,
                      hidden.isNotEmpty
                          ? Strings.get('ignored_msg')
                          : c.lastMessageOr(Strings.get('save_failed')));
                }
              },
              child: Text(Strings.get('ignore_btn')),
            ),
          ],
        ),
        Text(c.pickedOption(key, options),
            style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
      ],
    ));
  }

  List<Widget> _ignoredBlocks(BuildContext context) {
    final c = controller;
    final t = tokens;
final ignored = c.ignoredTasks().take(12).toList();
    final total = c.ignoredTasks().length;
    if (total == 0) return const [];
    return [
      _sectionHeader('${Strings.get('ignored_title')} ($total)'),
      for (final item in ignored)
        _card(Row(
          children: [
            Expanded(
                child: Text(item.label,
                    style: TextStyle(
                        color: t.faint, fontSize: t.fsSmall))),
            TextButton(
              onPressed: () {
                if (!c.unignoreKeys([item.key]) && context.mounted) {
                  _snack(context,
                      c.lastMessageOr(Strings.get('save_failed')));
                }
              },
              child: Text(Strings.get('restore')),
            ),
          ],
        )),
      if (total > 12)
        _faint('+ ${total - 12} ${Strings.get('more_tasks')}'),
    ];
  }

  Widget _nextLessonCard(DateTime now) {
    final c = controller;
    final t = tokens;
    final info = c.nextLesson(now);
    final headingColor =
        info.phase == 'running' ? t.green : t.accent;
    final bits = <Widget>[];
    if (info.headingLabel != null) {
      final heading = Text(info.headingLabel!,
          style: TextStyle(
              color: headingColor,
              fontSize: t.fsSmall,
              fontWeight: FontWeight.bold));
      if (info.alarmBadge != null) {
        bits.add(Wrap(spacing: 6, children: [
          heading,
          Chip(
              label: Text(info.alarmBadge!,
                  style: TextStyle(fontSize: t.fsSmall)),
              visualDensity: VisualDensity.compact),
        ]));
      } else {
        bits.add(heading);
      }
    }
    bits.add(Text(info.headline,
        style: TextStyle(
            color: t.text,
            fontSize: t.fsSection,
            fontWeight: FontWeight.bold)));
    if (info.meta.isNotEmpty) {
      bits.add(Text(info.meta,
          style: TextStyle(color: t.muted, fontSize: t.fsSmall)));
    }
    if (info.deltaText != null) {
      bits.add(Text(info.deltaText!,
          style: TextStyle(color: t.faint, fontSize: t.fsSmall)));
    }
    if (info.upcomingHeadline != null) {
      bits.add(Text(
          '${Strings.get('up_next')}: ${info.upcomingHeadline!}',
          style: TextStyle(color: t.muted, fontSize: t.fsSmall)));
    }
    if (info.statusLabel != null && info.statusLabel!.isNotEmpty) {
      bits.add(_statusChip(info.statusLabel!));
    }
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < bits.length; i++) ...[
          bits[i],
          if (i != bits.length - 1) const SizedBox(height: 4),
        ],
      ],
    ));
  }

  Widget _changeCard(String title, String? note) {
    final t = tokens;
    return _card(Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      color: t.text,
                      fontSize: t.fsSmall,
                      fontWeight: FontWeight.bold)),
              if (note != null && note.isNotEmpty)
                Text(note,
                    style: TextStyle(
                        color: t.muted, fontSize: t.fsSmall)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: note ?? '',
          child: Icon(Icons.change_circle_outlined,
              color: t.accent, size: 20),
        ),
      ],
    ));
  }

  Widget _noteCard(String text) {
    final t = tokens;
    return _card(Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration:
                BoxDecoration(color: t.accent, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    color: t.muted, fontSize: t.fsSmall))),
      ],
    ));
  }

  Widget _templatePicker(BuildContext context, String key,
      List<TemplateOption> options) {
    final c = controller;
    final t = tokens;
final labels = c.templateLabels(options);
    final current =
        (c.pickedTemplates[key] ?? 0).clamp(0, options.length - 1);
    return DropdownButtonFormField<int>(
      initialValue: options.isEmpty ? null : current,
      decoration: InputDecoration(
        labelText: Strings.get('choose_template'),
        isDense: true,
        filled: true,
        fillColor: t.surface,
      ),
      items: [
        for (var i = 0; i < options.length; i++)
          DropdownMenuItem(value: i, child: Text(labels[i])),
      ],
      onChanged: (v) =>
          c.chooseTemplate(key, '${v ?? 0}', options.length),
    );
  }

  void _signatureDialog(
      BuildContext context, ExcuseSendRequest request) {
    final t = tokens;
final field = TextEditingController();
    String? error;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(Strings.get('signature_ask_title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.get('signature_ask_p')),
              const SizedBox(height: 12),
              TextField(
                controller: field,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: Strings.get('signature'),
                  hintText: Strings.get('signature_hint'),
                  errorText: error,
                  filled: true,
                  fillColor: t.surface,
                ),
                onSubmitted: (_) => _submitSignature(
                    context, setState, field, (e) => error = e),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(Strings.get('cancel'))),
            ElevatedButton(
                onPressed: () => _submitSignature(
                    context, setState, field, (e) => error = e),
                child: Text(Strings.get('signature_save_send'))),
          ],
        ),
      ),
    );
  }

  Future<void> _submitSignature(
      BuildContext context,
      StateSetter setState,
      TextEditingController field,
      void Function(String? e) setError) async {
    final c = controller;
if (field.text.trim().isEmpty) {
      setState(() => setError(Strings.get('wiz_need_signature')));
      return;
    }
    final ok = await c.saveSignatureAndSend(field.text);
    if (context.mounted) {
      Navigator.of(context).pop();
      _snack(context,
          ok ? Strings.get('excuse_sent') : c.lastMessageOr(Strings.get('save_failed')));
    }
  }

  Widget _kindBadge(String kind) {
    final t = tokens;
const labels = {
      'late': 'status_late',
      'soon': 'status_soon',
      'early': 'status_early',
      'short': 'status_absent',
      'long': 'status_absent',
      'day': 'status_absent',
    };
    final label = Strings.get(labels[kind.toLowerCase()] ?? 'status_absent');
    Color color;
    switch (kind.toLowerCase()) {
      case 'late':
      case 'soon':
      case 'early':
        color = t.orange;
      default:
        color = t.muted;
    }
    return _statusChip(label, color: color);
  }

  Widget _statusChip(String label, {Color? color}) {
    final t = tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tintColor(color ?? t.muted, 0.12),
        borderRadius: BorderRadius.circular(t.radiusSm),
        border: Border.all(color: tintColor(color ?? t.muted, 0.45)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color ?? t.muted,
              fontSize: t.fsSmall,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _headerRow(String title, String updated) {
    final t = tokens;
    return Row(
      children: [
        Expanded(
            child: Text(title,
                style: TextStyle(
                    color: t.text,
                    fontSize: t.fsTitle,
                    fontWeight: FontWeight.bold))),
        if (updated.isNotEmpty)
          Text(updated,
              style:
                  TextStyle(color: t.faint, fontSize: t.fsSmall)),
      ],
    );
  }

  Widget _sectionHeader(String title) {
    final t = tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(title,
          style: TextStyle(
              color: t.text,
              fontSize: t.fsSection,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _card(Widget child) {
    final t = tokens;
    return Card(
      color: t.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd)),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }

  Widget _accentCard(Widget child) {
    final t = tokens;
    return Card(
      color: tintColor(t.accent, 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(color: tintColor(t.accent, 0.5)),
      ),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }

  Widget _faint(String text) {
    final t = tokens;
    return Text(text,
        style: TextStyle(color: t.faint, fontSize: t.fsSmall));
  }

  void _snack(BuildContext context, String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Null-safe access to the controller's last user message.
extension on TodayController {
  String lastMessageOr(String fallback) =>
      lastMessage.isEmpty ? fallback : lastMessage;
}
