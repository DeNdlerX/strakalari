import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../l10n/strings.dart';
import '../../widgets/overlays.dart';
import '../common/app_tokens.dart';
import '../common/format.dart';
import 'settings_controller.dart';
import 'settings_view.dart' show statusRowIcons;

/// The phone's morning brief (core `morning_brief.dart`): the switch, the
/// time, a switch per row (the background notification's items) and a
/// preview of the next brief that follows them in place.
class MorningBriefCard extends StatefulWidget {
  const MorningBriefCard({super.key, required this.controller});
  final SettingsController controller;

  @override
  State<MorningBriefCard> createState() => _MorningBriefCardState();
}

class _MorningBriefCardState extends State<MorningBriefCard> {
  SettingsController get c => widget.controller;

  Map<String, Object?> get _cfg =>
      Map<String, Object?>.of(c.config.cast<String, Object?>());

  void _save(Map<String, Object?> updates) {
    if (!c.saveQuiet(updates)) appSnack(context, Strings.get('save_failed'));
    setState(() {}); // the switches and the preview show what is stored
  }

  Future<void> _pickTime() async {
    final (hour, minute) = core.briefTimeOf(_cfg);
    final picked = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: hour, minute: minute));
    if (picked == null || !mounted) return;
    _save({'morning_brief_time': core.formatBriefTime(picked.hour, picked.minute)});
  }

  core.MorningBrief? _next() {
    final inputs = c.backgroundStatusInputs;
    if (inputs == null) return null;
    try {
      final briefs = core.upcomingMorningBriefs(inputs(), lang: Strings.lang);
      return briefs.isEmpty ? null : briefs.first;
    } catch (e) {
      // The switches still work.
      // ignore: avoid_print
      print('Warning: morning brief preview failed (${e.runtimeType}: $e)');
      return null;
    }
  }

  String _clock(int hour, int minute) =>
      '$hour:${minute.toString().padLeft(2, '0')}';

  Widget _preview(Tokens tok) {
    final next = _next();
    final body = <Widget>[];
    if (next == null) {
      body.add(Text(Strings.get('brief_none'),
          style: TextStyle(fontSize: tok.fsSmall, color: tok.muted)));
    } else {
      body.add(Text(
          Strings.format('brief_next', {
            'day': '${dayName(next.at, Strings.lang, short: true)} '
                '${czDay(next.at)}',
            'time': _clock(next.at.hour, next.at.minute),
          }),
          style: TextStyle(fontSize: tok.fsSmall, color: tok.muted)));
      body.add(Text(
          [Strings.get('app_title'), next.content.sub]
              .where((s) => s.isNotEmpty)
              .join(' · '),
          style: TextStyle(fontSize: tok.fsTiny, color: tok.faint)));
      for (final row in next.content.rows) {
        body.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Icon(statusRowIcons[row.kind], size: 16, color: tok.muted),
            Expanded(
                child: Text(row.line, style: TextStyle(fontSize: tok.fsSmall))),
          ],
        ));
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('brief:preview'),
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(Strings.get('bg_preview'),
                style: TextStyle(
                    fontSize: tok.fsSmall,
                    fontWeight: FontWeight.bold,
                    color: tok.muted)),
            ...body,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    final cfg = _cfg;
    final enabled = core.briefEnabled(cfg);
    final (hour, minute) = core.briefTimeOf(cfg);
    final picked = core.selectedBriefItems(cfg).toSet();
    final phone = c.wakeupPhone;
    final settings = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(Strings.get('brief_title'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(Strings.get('brief_hint'),
                style: TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
            SwitchListTile(
              key: const Key('brief:enabled'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(Strings.get('brief_enable')),
              value: enabled,
              onChanged: (on) {
                _save({'morning_brief_enabled': on});
                if (on) phone?.requestNotificationPermission();
              },
            ),
            if (enabled) ...[
              if (phone != null && !phone.notificationsEnabled) ...[
                Text(Strings.get('brief_notif_off'),
                    style: TextStyle(fontSize: tok.fsSmall, color: Colors.amber)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.notifications_active),
                    label: Text(Strings.get('notif_allow')),
                    onPressed: phone.requestNotificationPermission,
                  ),
                  TextButton(
                    onPressed: phone.openNotificationSettings,
                    child: Text(Strings.get('notif_open_settings')),
                  ),
                ]),
              ],
              ListTile(
                key: const Key('brief:time'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(Strings.get('brief_time')),
                trailing: Text(_clock(hour, minute),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                onTap: _pickTime,
              ),
              Text(Strings.get('brief_items_title'),
                  style: TextStyle(
                      fontSize: tok.fsSmall,
                      fontWeight: FontWeight.bold,
                      color: tok.muted)),
              for (final item in core.items)
                SwitchListTile(
                  key: Key('brief:item:$item'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(Strings.get('bg_item_$item')),
                  value: picked.contains(item),
                  onChanged: (on) => _save({
                    'morning_brief_items': core.withBriefItem(cfg, item, on),
                  }),
                ),
            ],
          ],
        ),
      ),
    );
    if (!enabled) return settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tok.gap,
      children: [settings, _preview(tok)],
    );
  }
}
