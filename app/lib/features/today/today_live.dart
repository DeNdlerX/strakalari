// Bridges [AppState] (Riverpod) to [TodayController] / [TodayView].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';

import '../common/app_tokens.dart';
import '../common/format.dart';
import '../common/schedule_logic.dart';
import 'today_controller.dart';
import 'today_view.dart';

/// Converts [AppState.stableBaseline] (`Map<(int, int), Object>`) into the
/// `Map<String, List<SlotBaseline>>` representation used by
/// [TodayController] and `TimetableController`.
Map<String, List<SlotBaseline>> convertStableBaseline(
    Map<(int, int), Object> raw) {
  final out = <String, List<SlotBaseline>>{};
  raw.forEach((slot, value) {
    final key = '${slot.$1}|${slot.$2}';
    if (value is core.SlotBaseline) {
      out[key] = [
        SlotBaseline(
          weekday: value.weekday,
          period: value.period,
          subject: value.subject,
          teacher: value.teacher,
          room: value.room,
          startMin: value.startMin,
        ),
      ];
    } else if (value is List) {
      out[key] = [
        for (final item in value)
          if (item is core.SlotBaseline)
            SlotBaseline(
              weekday: item.weekday,
              period: item.period,
              subject: item.subject,
              teacher: item.teacher,
              room: item.room,
              startMin: item.startMin,
            ),
      ];
    }
  });
  return out;
}

/// Builds a [TodayController] populated from [s] and wired so actions
/// mutate [s] directly.
TodayController todayControllerFor(AppState s, {DateTime? now}) {
  late final TodayController c;
  c = TodayController(
    config: Map<String, Object?>.of(s.config.data),
    onSave: s.save,
    onRefreshRequest: () => s.startRefresh('all'),
    onGo: s.go,
    onSend: (request) async {
      if (request.scope == 'day') {
        final dayIso = request.key.startsWith('day|')
            ? request.key.substring(4)
            : request.key;
        String template = '';
        for (final job in request.jobs) {
          if (job.customText != null) {
            template = job.customText!;
            break;
          }
        }
        final ok = s.submitDayExcuse(dayIso, template, request.perLesson);
        if (s.lastSnackMessage.isNotEmpty) {
          c.lastMessage = s.lastSnackMessage;
        }
        return ok;
      }
      final existing = s
          .excuseTasks()
          .where((t) => '${t['key']}' == request.key)
          .firstOrNull;
      if (existing == null) {
        s.logLine(Strings.get('excuse_failed'));
        c.lastMessage = Strings.get('excuse_failed');
        return false;
      }
      final job = request.jobs.isNotEmpty ? request.jobs.first : null;
      final ok = s.submitExcuse(existing, job?.customText ?? '');
      if (s.lastSnackMessage.isNotEmpty) {
        c.lastMessage = s.lastSnackMessage;
      }
      return ok;
    },
  );

  c.excuseTasksProvider = ({today}) => [
        for (final t in s.excuseTasks()) ExcuseTask.fromMap(t),
      ];
  c.ignoredTasksProvider = () => [
        for (final t in s.ignoredTasks()) ExcuseTask.fromMap(t),
      ];
  c.dayFullyAbsentProvider = (dayIso, {today}) => s.dayFullyAbsent(dayIso);
  c.dayExcusePlanProvider = (dayIso, {bool perLesson = false}) =>
      s.dayExcusePlan(dayIso, perLesson);

  c.timetable = {
    for (final e in s.timetable().entries)
      e.key: List<Object?>.of(e.value),
  };
  c.food = s.food();
  c.orders = Map<String, String>.of(s.orders);
  c.webOrders = Map<String, String>.of(s.webOrders);
  c.cancelledLunches = Set<String>.of(s.cancelledLunches);
  try {
    c.excuseHistory = List<Object?>.of(s.config.getExcuseHistory());
  } catch (_) {
    c.excuseHistory = [];
  }
  c.outboxFrom = parseCzDate('${s.data[core.sentExcusesFromKey] ?? ''}');
  c.stableBaseline = convertStableBaseline(s.stableBaseline());
  c.stableComplete = s.stableComplete();
  c.sentTaskKeys.addAll([
    for (final item in s.excuseLog)
      if ('${item['key'] ?? ''}'.isNotEmpty) '${item['key']}',
  ]);
  c.demoMode = s.demoMode;
  try {
    c.hasCredentials = core.hasValidCredentials(s.config.data).$1;
  } catch (_) {
    c.hasCredentials = false;
  }
  c.updatedLabel = s.updatedLabel;

  final alarm = s.nextWakeupAlarm(now);
  if (alarm != null) {
    c.nextAlarm = AlarmInfo(
      day: alarm.day,
      ringDay: alarm.ringDay,
      timeLabel: alarm.alarmTimeLabel,
    );
  }

  try {
    final term = s.yearPlan(now).defaultTerm;
    if (term != null) {
      c.plannerRecommended = [for (final o in term.recommended) o.day];
    }
  } catch (_) {
    c.plannerRecommended = [];
  }

  c.templateSource = (key) {
    final raw = s.get(key, const <Object?>[]);
    return raw is List ? List<Object?>.of(raw) : const <Object?>[];
  };

  c.ignoredKeys.addAll(s.ignoredExcuseKeys);
  c.sendingKeys.addAll(s.sendingExcuses);
  c.pickedTemplates.addAll(s.pickedTemplates);
  c.expandedDays.addAll(s.expandedDays);
  c.lastIgnoreError = s.lastIgnoreError;

  c.ignoreExcuseHook = (key) {
    final res = s.ignoreExcuse(key);
    c.ignoredKeys
      ..clear()
      ..addAll(s.ignoredExcuseKeys);
    c.lastIgnoreError = s.lastIgnoreError;
    return res;
  };
  c.ignoreDayHook = (dayIso) {
    final added = s.ignoreDay(dayIso);
    c.ignoredKeys
      ..clear()
      ..addAll(s.ignoredExcuseKeys);
    c.lastIgnoreError = s.lastIgnoreError;
    return added;
  };
  c.unignoreKeysHook = (keys) {
    final ok = s.unignoreKeys(keys);
    c.ignoredKeys
      ..clear()
      ..addAll(s.ignoredExcuseKeys);
    c.lastIgnoreError = s.lastIgnoreError;
    return ok;
  };
  c.chooseTemplateHook = (key, idx) {
    s.pickedTemplates[key] = idx;
  };
  c.setDayExpandedHook = (key, expanded) {
    s.setDayExpanded(key, expanded);
  };
  c.setExcuseDayPerLessonHook = s.setExcuseDayPerLesson;

  return c;
}

/// Live Riverpod-backed Today screen.
class LiveTodayView extends ConsumerWidget {
  final AppTokens tokens;
  final bool narrow;
  final DateTime? now;

  const LiveTodayView({
    super.key,
    required this.tokens,
    this.narrow = false,
    this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final controller = todayControllerFor(s, now: now);
    if (controller.excuseTasks(today: now).isNotEmpty) {
      s.tutorialOffer('excuse');
    }
    return TodayView(
      controller: controller,
      tokens: tokens,
      narrow: narrow,
      now: now,
    );
  }
}
