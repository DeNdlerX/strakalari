import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../l10n/strings.dart';
import '../../widgets/overlays.dart';
import '../common/format.dart';
import 'settings_controller.dart';
import 'settings_view.dart';

/// The phone's wake-up alarm card. Port of `automation.py::_wakeup`: the
/// switch, the minutes, and a block that follows the saved minutes, the
/// permissions and the timetable (hint, warnings, next alarm, skipped days).
/// Stands in when a controller has no phone wired (nothing to ask).
final _idlePhone = WakeupPhone(
  nextAlarm: () => null,
  skippedDays: () => const [],
  openSystemAlarm: (h, m, message, {int? weekday}) async => false,
  requestNotificationPermission: () {},
  openNotificationSettings: () {},
  openExactAlarmSettings: () {},
);

class WakeupCard extends StatefulWidget {
  final SettingsController controller;

  const WakeupCard({super.key, required this.controller});

  @override
  State<WakeupCard> createState() => _WakeupCardState();
}

class _WakeupCardState extends State<WakeupCard> {
  SettingsController get c => widget.controller;

  String _day(DateTime d) =>
      '${dayName(d, Strings.lang, short: true)} ${czDay(d)}';

  void _setSkipped(DateTime day, bool skip) {
    final skips = core.withSkippedDay(
        Map<String, Object?>.of(c.config.cast<String, Object?>()), day, skip);
    if (!c.save({'wakeup_skip_dates': skips})) {
      appSnack(context, Strings.get('save_failed'));
    }
  }

  Future<void> _openClock(core.WakeupAlarm alarm) async {
    final ok = await (c.wakeupPhone ?? _idlePhone).openSystemAlarm(
        alarm.alarmDt.hour, alarm.alarmDt.minute, 'Strakaláři · ${alarm.subject}',
        weekday: core.clockAppWeekday(alarm, clock.now()));
    if (!ok && mounted) appSnack(context, Strings.get('wakeup_clock_failed'));
  }

  Widget _small(String text, {Color? color, bool bold = false}) => Text(text,
      style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: bold ? FontWeight.bold : null));

  List<Widget> _liveRows() {
    final phone = c.wakeupPhone ?? _idlePhone;
    final enabled = c.get('wakeup_enabled', false) == true;
    final minutes = core.clampWakeupMinutes(c.get('wakeup_minutes_before', 60));
    final rows = <Widget>[
      Text(Strings.format('wakeup_hint', {'n': minutes})),
    ];
    if (!enabled) return rows;
    final scheme = Theme.of(context).colorScheme;
    if (!phone.notificationsEnabled) {
      rows
        ..add(_small(Strings.get('wakeup_notif_off'), color: Colors.amber))
        ..add(Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.notifications_active),
            label: Text(Strings.get('notif_allow')),
            onPressed: phone.requestNotificationPermission,
          ),
          TextButton(
            onPressed: phone.openNotificationSettings,
            child: Text(Strings.get('notif_open_settings')),
          ),
        ]));
    }
    if (!phone.exactAlarmsAllowed) {
      rows
        ..add(_small(Strings.get('wakeup_exact_off'), color: Colors.amber))
        ..add(Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.alarm_on),
            label: Text(Strings.get('wakeup_exact_allow')),
            onPressed: phone.openExactAlarmSettings,
          ),
        ));
    }

    final alarm = phone.nextAlarm();
    if (alarm == null) {
      rows.add(_small(Strings.get('wakeup_none')));
    } else {
      // Named by the day it rings; a lesson on another day (the minutes
      // reach back past midnight) gets its own day.
      final key =
          alarm.ringDay == alarm.day ? 'wakeup_next' : 'wakeup_next_eve';
      rows.add(_small(
          Strings.format(key, {
            'day': _day(alarm.ringDay),
            'alarm': alarm.alarmTimeLabel,
            'subject': alarm.subject,
            'lesson': alarm.lessonTimeLabel,
            'lesson_day': _day(alarm.day),
          }),
          color: scheme.primary,
          bold: true));
      rows.add(Wrap(spacing: 8, runSpacing: 8, children: [
        TextButton.icon(
          icon: const Icon(Icons.alarm_off),
          label: Text(Strings.get('wakeup_skip_next')),
          onPressed: () => _setSkipped(alarm.day, true),
        ),
        TextButton.icon(
          icon: const Icon(Icons.alarm_add),
          label: Text(Strings.get('wakeup_set_clock')),
          onPressed: () => _openClock(alarm),
        ),
      ]));
      if (core.clockAppWeekday(alarm, clock.now()) != null) {
        rows.add(Text(Strings.format('wakeup_clock_weekly', {
          'day': _day(alarm.ringDay),
          'time': alarm.alarmTimeLabel,
        })));
      }
    }

    // Only skips whose alarm is still ahead: once it would have rung,
    // restoring the day gives nothing back.
    final skipped = phone.skippedDays();
    if (skipped.isNotEmpty) {
      rows.add(_small(Strings.get('wakeup_skipped')));
      rows.add(Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (day, a) in skipped)
          TextButton.icon(
            icon: const Icon(Icons.restore),
            label: Text(a == null
                ? Strings.format('wakeup_restore_day', {'day': _day(day)})
                : Strings.format('wakeup_restore_alarm',
                    {'day': _day(a.ringDay), 'time': a.alarmTimeLabel})),
            onPressed: () => _setSkipped(day, false),
          ),
      ]));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = c.get('wakeup_enabled', false) == true;
    final minutes = core.clampWakeupMinutes(c.get('wakeup_minutes_before', 60));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Strings.get('wakeup_title'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: Text(Strings.get('wakeup_enable')),
              value: enabled,
              onChanged: (on) {
                if (!c.save({'wakeup_enabled': on})) {
                  appSnack(context, Strings.get('save_failed'));
                } else if (on) {
                  c.wakeupPhone?.requestNotificationPermission();
                }
              },
            ),
            AutosaveField(
              controller: c,
              label: Strings.get('wakeup_minutes'),
              draftKey: 'rule:wakeup_min',
              configKey: 'wakeup_minutes_before',
              fallback: '$minutes',
              parse: (raw) {
                if (double.tryParse(raw.trim().replaceAll(',', '.')) == null) {
                  throw FormatException(Strings.get('wakeup_minutes_invalid'));
                }
                return core.clampWakeupMinutes(raw);
              },
              // The minutes only repaint this card, not the whole screen.
              onSaved: (_) => setState(() {}),
            ),
            ..._liveRows(),
          ],
        ),
      ),
    );
  }
}
