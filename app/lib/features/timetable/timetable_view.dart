import 'package:flutter/material.dart';

import '../common/app_tokens.dart';
import '../common/format.dart';
import '../common/lesson_model.dart';
import '../common/schedule_logic.dart';
import 'timetable_controller.dart';

/// Timetable (Rozvrh) screen — port of `views/timetable.py`.
///
/// Week navigation with a real grid table (days × periods sharing the
/// width) plus the list view (one card per day, past days folded).
/// On narrow screens the grid scrolls sideways with a fixed day
/// column; wider screens stretch cells to fill the width. Tapping a
/// cell opens the detail dialog. Stateless; state lives in
/// [TimetableController] via [ListenableBuilder].
class TimetableView extends StatelessWidget {
  final TimetableController controller;
  final AppTokens tokens;

  /// Phone layout (the Shell sets this from the page width).
  final bool narrow;
  final DateTime? now;

  const TimetableView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
    this.now,
  });

  static const double gutterW = 72;
  static const double phoneGutterW = 52;
  static const double rowH = 68;
  static const double headerH = 38;
  static const double gap = 4;

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
    final s = c.s;
    final header = _headerRow();
    final weeks = c.weeks();
    if (weeks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          header,
          SizedBox(height: t.gap),
          _card(Text(s.get('no_data'),
              style:
                  TextStyle(color: t.faint, fontSize: t.fsBody))),
          if (c.demoMode)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(s.get('need_credentials'),
                  style: TextStyle(
                      color: t.faint, fontSize: t.fsSmall)),
            ),
        ],
      );
    }
    final showStable =
        c.showStableTimetable && c.stableBaseline.isNotEmpty;
    late Map<DateTime, List<Map<String, Object?>>> weekDays;
    late DateTime current;
    late String navLabel;
    if (showStable) {
      final today = DateTime(now.year, now.month, now.day);
      weekDays = stableTemplateWeek(
          c.stableBaseline, weekMonday(today));
      current = weekMonday(today);
      navLabel = s.get('stable_timetable');
    } else {
      current = c.resolveCurrent(weeks, today: now);
      weekDays = weeks[current] ?? {};
      final fri = current.add(const Duration(days: 4));
      final weekNo = _isoWeek(current);
      navLabel = '${s.get('week')} $weekNo · '
          '${current.day.toString().padLeft(2, '0')}.${current.month.toString().padLeft(2, '0')}. – '
          '${fri.day.toString().padLeft(2, '0')}.${fri.month.toString().padLeft(2, '0')}.${fri.year}';
    }
    final nav = _nav(context, navLabel, showStable);
    final legend = _legend();
    final isTable = c.timetableView != 'list';
    if (narrow) {
      // Phone: one scrolling page; the body scrolls as a whole.
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          header,
          SizedBox(height: t.gap),
          nav,
          SizedBox(height: t.gap),
          if (isTable)
            _tableView(context, weekDays, current, now, showStable)
          else
            ..._listView(context, weekDays, now),
          SizedBox(height: t.gap),
          legend,
          const SizedBox(height: 24),
        ],
      );
    }
    Widget content;
    if (isTable) {
      content = Expanded(
          child: SingleChildScrollView(
              child: _tableView(context, weekDays, current, now,
                  showStable)));
    } else {
      content = Expanded(
          child: ListView(children: [
        ..._listView(context, weekDays, now),
        const SizedBox(height: 24),
      ]));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: t.gap),
          nav,
          SizedBox(height: t.gap),
          legend,
          SizedBox(height: t.gap),
          content,
        ],
      ),
    );
  }

  int _isoWeek(DateTime day) {
    // ISO week number (Monday-based; Thursday decides the week).
    final thursday =
        DateTime(day.year, day.month, day.day).add(Duration(days: 4 - day.weekday));
    final jan4 = DateTime(thursday.year, 1, 4);
    final week1Monday =
        DateTime(jan4.year, jan4.month, jan4.day).subtract(Duration(days: jan4.weekday - 1));
    return thursday.difference(week1Monday).inDays ~/ 7 + 1;
  }

  Widget _headerRow() {
    final c = controller;
    final t = tokens;
    return Row(
      children: [
        Expanded(
            child: Text(c.s.get('timetable_title'),
                style: TextStyle(
                    color: t.text,
                    fontSize: 20,
                    fontWeight: FontWeight.bold))),
      ],
    );
  }

  Widget _nav(BuildContext context, String label, bool showStable) {
    final c = controller;
    final t = tokens;
    final s = c.s;
    final prev = IconButton(
      tooltip: showStable ? null : s.get('prev_week'),
      icon: const Icon(Icons.chevron_left),
      onPressed: showStable ? null : () => c.stepWeek(-1),
    );
    final next = IconButton(
      tooltip: showStable ? null : s.get('next_week'),
      icon: const Icon(Icons.chevron_right),
      onPressed: showStable ? null : () => c.stepWeek(1),
    );
    final labelWidget = Expanded(
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: t.text,
                fontSize: t.fsBody,
                fontWeight: FontWeight.bold)));
    final stableBtn = showStable
        ? ElevatedButton(
            onPressed: () => c.setShowStable(false),
            child: Text(s.get('stable_view')))
        : OutlinedButton(
            onPressed: () => c.setShowStable(true),
            child: Text(s.get('stable_view')));
    final toggle = SegmentedButton<String>(
      segments: [
        ButtonSegment(
            value: 'table',
            label: Text(s.get('view_table')),
            icon: const Icon(Icons.grid_view_outlined, size: 16)),
        ButtonSegment(
            value: 'list',
            label: Text(s.get('view_list')),
            icon: const Icon(Icons.view_agenda_outlined, size: 16)),
      ],
      selected: {
        c.timetableView == 'list' ? 'list' : 'table'
      },
      onSelectionChanged: (sel) =>
          c.setTimetableView(sel.first),
      showSelectedIcon: false,
    );
    if (narrow) {
      return Column(
        children: [
          Row(children: [prev, labelWidget, next]),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                  onPressed: () => c.goTimetableWeek(null),
                  child: Text(s.get('this_week'))),
              stableBtn,
              toggle,
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        prev,
        labelWidget,
        next,
        const SizedBox(width: 8),
        TextButton(
            onPressed: () => c.goTimetableWeek(null),
            child: Text(s.get('this_week'))),
        stableBtn,
        const Spacer(),
        toggle,
      ],
    );
  }

  Widget _legend() {
    final t = tokens;
    final s = controller.s;
    Widget swatch(Widget box, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            box,
            const SizedBox(width: 6),
            Text(label,
                style:
                    TextStyle(color: t.muted, fontSize: t.fsSmall)),
          ],
        );
    Widget box(Color? fill, [Border? border]) => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
              color: fill, border: border,
              borderRadius: BorderRadius.circular(4)),
        );
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        swatch(
            Container(width: 3, height: 14, color: t.red),
            s.get('status_absent')),
        swatch(
            Container(width: 3, height: 14, color: t.orange),
            s.get('legend_late_early')),
        swatch(
            Container(width: 3, height: 14, color: t.green),
            s.get('status_excused')),
        swatch(
            box(tintColor(t.accent, 0.22),
                Border.all(color: t.accent)),
            s.get('legend_change')),
        swatch(
            Text('Aa',
                style: TextStyle(
                    color: t.faint,
                    fontSize: t.fsSmall,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: t.faint)),
            s.get('status_lesson_cancelled')),
        swatch(
            Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                    color: t.accent, shape: BoxShape.circle)),
            s.get('note_label')),
        swatch(box(null, Border.all(color: t.accent, width: 2)),
            s.get('legend_now')),
      ],
    );
  }

  // -- table -------------------------------------------------------------------

  Widget _tableView(
      BuildContext context,
      Map<DateTime, List<Map<String, Object?>>> weekDays,
      DateTime current,
      DateTime now,
      bool showStable) {
    final c = controller;
    final days = weekDays.keys.toList()..sort();
    final byDayPeriod = <DateTime, Map<int, List<Map<String, Object?>>>>{};
    for (final day in days) {
      for (final raw in weekDays[day] ?? const []) {
        final period = c.periodOf(raw, day);
        if (period == null) continue;
        (byDayPeriod[day] ??= {})
            .putIfAbsent(period, () => [])
            .add(raw);
      }
    }
    final rawPeriods = {
      for (final perDay in byDayPeriod.values) ...perDay.keys
    };
    if (rawPeriods.isEmpty) {
      return _card(Text(controller.s.get('no_lessons_today'),
          style: TextStyle(
              color: tokens.faint, fontSize: tokens.fsBody)));
    }
    final first = rawPeriods.reduce((a, b) => a < b ? a : b);
    final last = rawPeriods.reduce((a, b) => a > b ? a : b);
    final periods = [
      for (var p = first < 1 ? first : 1; p <= last; p++) p
    ];
    final today = DateTime(now.year, now.month, now.day);
    int? focusPeriod;
    String focusKind = '';
    if (weekDays.containsKey(today)) {
      final focus = c.focusPeriod(
          weekDays[today] ?? const [], today, now);
      focusPeriod = focus.period;
      focusKind = focus.kind;
    }
    if (narrow) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final cellW = c.phoneCellWidth(
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 390.0,
              periods.length);
          return _phoneTable(context, days, periods, byDayPeriod,
              today, focusPeriod, focusKind, cellW);
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxChars = c.cellChars(
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 1240.0,
            periods.length);
        final headerCells = <Widget>[
          const SizedBox(width: gutterW, height: headerH),
        ];
        for (final p in periods) {
          headerCells.add(Expanded(
              child: _periodHeader(
                  p,
                  c.periodTime(weekDays, p),
                  p == focusPeriod)));
        }
        final rows = <Widget>[
          Row(children: headerCells),
        ];
        for (final day in days) {
          final isToday = day == today;
          final cells = <Widget>[
            _dayGutter(day,
                c.taught(weekDays[day] ?? const []).length,
                isToday, gutterW),
          ];
          final span = c.daySpan(byDayPeriod[day]);
          for (final period in periods) {
            final focus = isToday && period == focusPeriod
                ? focusKind
                : '';
            cells.add(Expanded(
                child: _gridCell(
                    context,
                    c.combinedCell(
                        byDayPeriod[day]?[period]),
                    day,
                    focus,
                    maxChars,
                    inSpan: span.contains(period))));
          }
          rows.add(Container(
            decoration: BoxDecoration(
              color: isToday ? tintColor(tokens.accent, 0.08) : null,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
            ),
            padding: const EdgeInsets.all(2),
            child: Row(children: cells),
          ));
        }
        return Column(
            spacing: gap,
            children: rows);
      },
    );
  }

  Widget _phoneTable(
      BuildContext context,
      List<DateTime> days,
      List<int> periods,
      Map<DateTime, Map<int, List<Map<String, Object?>>>> byDayPeriod,
      DateTime today,
      int? focusPeriod,
      String focusKind,
      double cellW) {
    final c = controller;
    final maxChars = (((cellW - 24) / 7.5).truncate()).clamp(3, 1 << 30);
    final gutters = <Widget>[const SizedBox(height: headerH)];
    final rows = <Widget>[
      Row(
        children: [
          for (final p in periods)
            SizedBox(
                width: cellW,
                child: _periodHeader(p,
                    c.periodTime(_asWeekDays(byDayPeriod), p),
                    p == focusPeriod)),
        ],
      ),
    ];
    for (final day in days) {
      final isToday = day == today;
      gutters.add(SizedBox(
        height: rowH + 4,
        child: Center(
            child: _dayGutter(
                day,
                c.taught(_lessonsOf(byDayPeriod, day)).length,
                isToday,
                phoneGutterW)),
      ));
      final span = c.daySpan(byDayPeriod[day]);
      rows.add(Container(
        height: rowH + 4,
        decoration: BoxDecoration(
          color: isToday ? tintColor(tokens.accent, 0.08) : null,
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            for (final period in periods)
              SizedBox(
                width: cellW,
                child: _gridCell(
                    context,
                    c.combinedCell(
                        byDayPeriod[day]?[period]),
                    day,
                    isToday && period == focusPeriod ? focusKind : '',
                    maxChars,
                    inSpan: span.contains(period)),
              ),
          ],
        ),
      ));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(children: gutters),
        const SizedBox(width: gap),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rows),
          ),
        ),
      ],
    );
  }

  Map<DateTime, List<Map<String, Object?>>> _asWeekDays(
          Map<DateTime, Map<int, List<Map<String, Object?>>>> byDayPeriod) =>
      {
        for (final e in byDayPeriod.entries)
          e.key: [for (final l in e.value.values) ...l],
      };

  List<Map<String, Object?>> _lessonsOf(
          Map<DateTime, Map<int, List<Map<String, Object?>>>> byDayPeriod,
          DateTime day) =>
      [for (final l in (byDayPeriod[day] ?? const {}).values) ...l];

  Widget _periodHeader(int period, String timeLabel, bool active) {
    final t = tokens;
    return SizedBox(
      height: headerH,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$period.',
              style: TextStyle(
                  color: active ? t.accent : t.text,
                  fontSize: t.fsSmall,
                  fontWeight: FontWeight.bold)),
          if (timeLabel.isNotEmpty)
            Text(timeLabel,
                style:
                    TextStyle(color: t.faint, fontSize: t.fsTiny)),
        ],
      ),
    );
  }

  Widget _dayGutter(
      DateTime day, int count, bool isToday, double width) {
    final t = tokens;
    final s = controller.s;
    return Container(
      width: width,
      height: rowH,
      decoration: BoxDecoration(
        color: isToday ? t.accent : t.surface,
        borderRadius: BorderRadius.circular(t.radiusSm),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(dayName(day, s.lang, short: true),
              style: TextStyle(
                  color: isToday ? t.accentText : t.text,
                  fontSize: t.fsSection,
                  fontWeight: FontWeight.bold)),
          Text(czDay(day),
              style: TextStyle(
                  color: isToday ? t.accentText : t.faint,
                  fontSize: t.fsTiny)),
        ],
      ),
    );
  }

  Widget _gridCell(BuildContext context, Map<String, Object?>? raw,
      DateTime day, String focus, int maxChars,
      {bool inSpan = false}) {
    final c = controller;
    final t = tokens;
    if (raw == null) {
      if (!inSpan) return const SizedBox(height: rowH);
      return Container(
        height: rowH,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(t.radiusSm),
        ),
      );
    }
    final look = c.look(raw, day);
    final subject = c.cellSubject(
        raw,
        look.parsed.subject.isEmpty ? '?' : look.parsed.subject,
        maxChars);
    Color? fill;
    switch (look.fill) {
      case 'accent':
        fill = tintColor(t.accent, 0.22);
      case 'bar':
        fill = tintColor(_barColor(look.bar), 0.12);
      case 'card':
        fill = t.card;
      case 'none':
        fill = Colors.transparent;
    }
    Border? frame;
    if (focus == 'now') {
      frame = Border.all(color: t.accent, width: 2);
    } else if (focus == 'next') {
      frame = Border.all(color: t.accent);
    } else if (look.cancelled) {
      frame = Border.all(color: t.border);
    }
    return Tooltip(
      message: look.tooltip,
      child: InkWell(
        onTap: () => _detailDialog(context, raw, day),
        borderRadius: BorderRadius.circular(t.radiusSm),
        child: Container(
          height: rowH,
          decoration: BoxDecoration(
              color: fill,
              border: frame,
              borderRadius: BorderRadius.circular(t.radiusSm)),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (look.bar.isNotEmpty)
                Container(
                    width: 3,
                    height: rowH - 16,
                    decoration: BoxDecoration(
                        color: _barColor(look.bar),
                        borderRadius: BorderRadius.circular(2))),
              if (look.bar.isNotEmpty) const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _subjectText(subject, look),
                    _metaText(look),
                    _tagRow(look),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _barColor(String bar) {
    final t = tokens;
    switch (bar) {
      case 'absent':
        return t.red;
      case 'late':
        return t.orange;
      case 'excused':
        return t.green;
      default:
        return t.muted;
    }
  }

  Widget _subjectText(String value, LessonLook look) {
    final t = tokens;
    Color color;
    if (look.cancelled) {
      color = t.faint;
    } else if (look.changed.contains('subject') ||
        look.changed.contains('added')) {
      color = t.accent;
    } else {
      color = t.text;
    }
    return Text(value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: color,
            fontSize: t.fsBody,
            fontWeight: FontWeight.bold,
            decoration:
                look.cancelled ? TextDecoration.lineThrough : null,
            decorationColor: t.faint));
  }

  Widget _metaText(LessonLook look) {
    final t = tokens;
    final room = look.parsed.room;
    final surname = teacherSurname(look.parsed.teacher);
    if (room.isEmpty && surname.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text.rich(
      TextSpan(children: [
        if (room.isNotEmpty)
          TextSpan(
              text: room,
              style: TextStyle(
                  color: look.changed.contains('room')
                      ? t.accent
                      : t.muted,
                  fontWeight: FontWeight.w600)),
        if (room.isNotEmpty && surname.isNotEmpty)
          TextSpan(
              text: ' · ',
              style: TextStyle(color: t.faint)),
        if (surname.isNotEmpty)
          TextSpan(
              text: surname,
              style: TextStyle(
                  color: look.changed.contains('teacher')
                      ? t.accent
                      : t.faint)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: t.fsTiny),
    );
  }

  Widget _tagRow(LessonLook look) {
    final t = tokens;
    if (look.tag.isEmpty &&
        (look.diff.note.isEmpty || look.diff.isChange)) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (look.tag.isNotEmpty)
          Expanded(
              child: Text(look.tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _tagColor(look.tagColor),
                      fontSize: t.fsTiny,
                      fontWeight: FontWeight.w600))),
        if (look.diff.note.isNotEmpty && !look.diff.isChange)
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                  color: t.accent, shape: BoxShape.circle)),
      ],
    );
  }

  Color _tagColor(String key) {
    final t = tokens;
    switch (key) {
      case 'absent':
        return t.red;
      case 'late':
        return t.orange;
      case 'excused':
        return t.green;
      case 'accent':
        return t.accent;
      case 'muted':
        return t.muted;
      default:
        return t.faint;
    }
  }

  // -- list --------------------------------------------------------------------

  List<Widget> _listView(BuildContext context,
      Map<DateTime, List<Map<String, Object?>>> weekDays, DateTime now) {
    final c = controller;
    final t = tokens;
    final s = c.s;
    final today = DateTime(now.year, now.month, now.day);
    final days = weekDays.keys.toList()..sort();
    final cards = <Widget>[];
    for (final day in days) {
      final lessons = (weekDays[day] ?? const []).toList()
        ..sort((a, b) =>
            c.listOrderKey(a, day).compareTo(c.listOrderKey(b, day)));
      final isToday = day == today;
      final title = '${dayName(day, s.lang)} ${czDayYear(day)}';
      final focus = c.focusPeriod(
          weekDays[day] ?? const [], day, now);
      final rows = <Widget>[];
      if (lessons.isEmpty) {
        rows.add(Text(s.get('no_lessons_today'),
            style: TextStyle(
                color: t.faint, fontSize: t.fsSmall)));
      }
      final byPeriod = <int, List<Map<String, Object?>>>{};
      for (final lesson in lessons) {
        final period = c.periodOf(lesson, day);
        if (period != null) {
          (byPeriod[period] ??= []).add(lesson);
        }
      }
      for (final period in c.daySpan(byPeriod)) {
        if (!byPeriod.containsKey(period)) {
          rows.add(_pauseRow(period,
              c.periodTime(weekDays, period)));
          continue;
        }
        for (final lesson in byPeriod[period]!) {
          final isFocus = period == focus.period &&
              LessonRow.fromLegacy(lesson, day).status != 'cancelled';
          rows.add(_lessonRow(context, lesson, day,
              focus: isFocus ? focus.kind : ''));
        }
      }
      for (final lesson in lessons) {
        if (c.periodOf(lesson, day) == null) {
          rows.add(_lessonRow(context, lesson, day));
        }
      }
      final dayKey = 'tt:${isoDay(day)}';
      final expanded = c.isDayExpanded(dayKey,
          defaultValue: !(weekDays.containsKey(today) && day.isBefore(today)));
      cards.add(Card(
        color: t.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd),
          side: isToday
              ? BorderSide(color: t.accent)
              : BorderSide.none,
        ),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: (v) =>
              c.setDayExpanded(dayKey, v),
          title: isToday
              ? Row(
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: t.accent,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Chip(
                        label: Text(s.get('today_badge'),
                            style:
                                TextStyle(fontSize: t.fsSmall)),
                        visualDensity: VisualDensity.compact),
                  ],
                )
              : Text(title),
          subtitle: Text(c.daySummary(lessons, day),
              style: TextStyle(
                  color: t.faint, fontSize: t.fsSmall)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                  spacing: 4,
                  children: rows),
            ),
          ],
        ),
      ));
    }
    return cards;
  }

  Widget _lessonRow(BuildContext context, Map<String, Object?> lesson,
      DateTime day,
      {String focus = ''}) {
    final c = controller;
    final t = tokens;
    final look = c.look(lesson, day);
    final period = extractLessonNum(look.parsed.time) ??
        look.parsed.period;
    final trailing = <Widget>[];
    if (look.tag.isNotEmpty) {
      trailing.add(Text(look.tag,
          style: TextStyle(
              color: _tagColor(look.tagColor),
              fontSize: t.fsSmall,
              fontWeight: FontWeight.bold)));
    }
    if (look.diff.note.isNotEmpty && !look.diff.isChange) {
      trailing.add(Tooltip(
          message: '${c.s.get('note_label')}: ${look.diff.note}',
          child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: t.accent,
                  shape: BoxShape.circle))));
    }
    Color? bar;
    if (look.bar.isNotEmpty) {
      bar = _barColor(look.bar);
    } else if (look.diff.isChange && !look.cancelled) {
      bar = t.accent;
    }
    return Tooltip(
      message: look.tooltip,
      child: InkWell(
        onTap: () => _detailDialog(context, lesson, day),
        borderRadius: BorderRadius.circular(t.radiusSm),
        child: Container(
          decoration: BoxDecoration(
            color: look.fill == 'card'
                ? null
                : _fillColor(look, bar),
            border: focus.isNotEmpty
                ? Border.all(color: t.accent)
                : null,
            borderRadius: BorderRadius.circular(t.radiusSm),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(period != null ? '$period.' : '',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: focus.isNotEmpty
                            ? t.accent
                            : t.text,
                        fontSize: t.fsSmall,
                        fontWeight: FontWeight.bold)),
              ),
              SizedBox(
                width: 96,
                child: Text(shortTime(look.parsed.time),
                    style: TextStyle(
                        color: t.faint,
                        fontSize: t.fsSmall)),
              ),
              Container(
                  width: 3,
                  height: 32,
                  decoration: BoxDecoration(
                      color: bar,
                      borderRadius:
                          BorderRadius.circular(2))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _subjectText(
                        look.parsed.subject.isEmpty
                            ? '?'
                            : look.parsed.subject,
                        look),
                    _metaText(look),
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }

  Color? _fillColor(LessonLook look, Color? bar) {
    final t = tokens;
    switch (look.fill) {
      case 'accent':
        return tintColor(t.accent, 0.22);
      case 'bar':
        return bar == null ? null : tintColor(bar, 0.12);
      case 'none':
        return Colors.transparent;
      default:
        return null;
    }
  }

  Widget _pauseRow(int period, String timeLabel) {
    final t = tokens;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text('$period.',
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: t.faint,
                    fontSize: t.fsSmall,
                    fontWeight: FontWeight.bold)),
          ),
          SizedBox(
            width: 96,
            child: Text(timeLabel,
                style: TextStyle(
                    color: t.faint, fontSize: t.fsSmall)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 28,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.border),
                borderRadius:
                    BorderRadius.circular(t.radiusSm),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -- detail dialog -------------------------------------------------------------

  void _detailDialog(
      BuildContext context, Map<String, Object?> lesson, DateTime day) {
    final c = controller;
    final t = tokens;
    final s = c.s;
    final detail = c.detail(lesson, day);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(detail.subject,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(detail.subtitle,
                    style: TextStyle(
                        color: t.muted, fontSize: t.fsSmall)),
                if (detail.badges.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final b in detail.badges)
                        Chip(
                            label: Text(b,
                                style: TextStyle(
                                    fontSize: t.fsSmall)),
                            visualDensity:
                                VisualDensity.compact),
                    ],
                  ),
                ],
                const Divider(height: 16),
                for (final f in detail.fields) ...[
                  _kvRow(f.label, f.value, accent: f.accent),
                  const SizedBox(height: 2),
                ],
                if (detail.changeSummary != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(detail.changeSummary!,
                        style: TextStyle(
                            color: t.accent,
                            fontSize: t.fsSmall,
                            fontWeight: FontWeight.bold)),
                  ),
                if (detail.note != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: t.overlay,
                      border: Border.all(color: t.accent),
                      borderRadius:
                          BorderRadius.circular(t.radiusSm),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outlined,
                            size: 16, color: t.accent),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                '${s.get('note_label')}: ${detail.note!}',
                                style: TextStyle(
                                    color: t.text,
                                    fontSize: t.fsSmall))),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.get('close'))),
        ],
      ),
    );
  }

  Widget _kvRow(String label, String value, {bool accent = false}) {
    final t = tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 110,
            child: Text(label,
                style:
                    TextStyle(color: t.faint, fontSize: t.fsSmall))),
        Expanded(
            child: Text(value,
                style: TextStyle(
                    color: accent ? t.accent : t.text,
                    fontSize: t.fsSmall,
                    fontWeight: accent
                        ? FontWeight.bold
                        : FontWeight.normal))),
      ],
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
}
