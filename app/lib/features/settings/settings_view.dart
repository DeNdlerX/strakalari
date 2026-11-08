import 'package:flutter/material.dart';

import 'package:app/features/settings/settings_controller.dart';
import 'package:app/widgets/overlays.dart';

const List<String> kNotificationEvents = [
  'excuse_sent',
  'excuse_needs_confirm',
  'refresh_done',
  'refresh_failed',
  'lunch_ordered',
  'lunch_skipped',
  'planner_suggestion',
  'automation_failed',
  'new_mark',
  'new_quarterly_mark',
  'new_absence',
  'timetable_change',
  'update_available',
];

/// Autosaving text field: typing fills drafts, blur/Enter saves quietly.
/// Port of SettingsView._auto (no re-render; unchanged → no write).
class AutosaveField extends StatefulWidget {
  final SettingsController controller;
  final String label;
  final String draftKey;
  final String configKey;
  final String fallback;
  final bool password;
  final bool multiline;
  final String hint;
  final Object? Function(String raw)? parse;
  final void Function(Object? value)? onSaved;

  /// Draft-only field (no save on blur): the commit keeps the draft
  /// for an explicit button handler (port of `_text`).
  final bool draftOnly;

  const AutosaveField({
    super.key,
    required this.controller,
    required this.label,
    required this.draftKey,
    required this.configKey,
    this.fallback = '',
    this.password = false,
    this.multiline = false,
    this.hint = '',
    this.parse,
    this.onSaved,
    this.draftOnly = false,
  });

  @override
  State<AutosaveField> createState() => _AutosaveFieldState();
}

class _AutosaveFieldState extends State<AutosaveField> {
  late final TextEditingController text;
  late final FocusNode focus;

  @override
  void initState() {
    super.initState();
    text = TextEditingController(
        text: widget.controller.draft(widget.draftKey, widget.fallback));
    focus = FocusNode();
    focus.addListener(() {
      if (!focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  void _commit() {
    final c = widget.controller;
    var val = text.text;
    if (widget.draftOnly) {
      // No save: the button handler reads the draft.
      c.setDraft(widget.draftKey, val);
      return;
    }
    if (widget.password && val.trim().isEmpty) return;
    Object? newVal = val;
    if (widget.parse != null) {
      try {
        newVal = widget.parse!(val);
      } catch (_) {
        appSnack(context, Str.t('save_failed'));
        return;
      }
    }
    if (!widget.password &&
        SettingsController.sameValue(c.get(widget.configKey), newVal)) {
      c.drafts.remove(widget.draftKey);
      _showValue(newVal);
      return; // focus moved without an edit: nothing to save
    }
    if (!c.saveQuiet({widget.configKey: newVal})) return;
    if (!widget.password) {
      c.drafts.remove(widget.draftKey);
      _showValue(newVal);
    }
    widget.onSaved?.call(newVal);
  }

  void _showValue(Object? value) {
    final s = value == null ? '' : '$value';
    if (text.text != s) {
      text.text = s;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: Key('auto:${widget.draftKey}'),
      controller: text,
      focusNode: focus,
      decoration: InputDecoration(
          labelText: widget.label, hintText: widget.hint.isEmpty ? null : widget.hint),
      obscureText: widget.password,
      maxLines: widget.multiline ? 3 : 1,
      onChanged: (v) =>
          widget.controller.setDraft(widget.draftKey, v),
      onSubmitted: (_) => _commit(),
    );
  }
}

/// One template-list editor (names + texts). Port of common._tpl_editor.
class TemplateEditor extends StatefulWidget {
  final SettingsController controller;
  final String configKey;
  final String titleKey;

  const TemplateEditor(
      {super.key,
      required this.controller,
      required this.configKey,
      required this.titleKey});

  @override
  State<TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<TemplateEditor> {
  late List<Map<String, String>> values;

  @override
  void initState() {
    super.initState();
    values = _load();
  }

  List<Map<String, String>> _load() {
    final stored = widget.controller.get(widget.configKey, []);
    final out = <Map<String, String>>[];
    if (stored is List) {
      for (final v in stored) {
        if (v is Map) {
          out.add({
            'name': '${v['name'] ?? ''}',
            'text': '${v['text'] ?? ''}'
          });
        } else {
          out.add({'name': '', 'text': '$v'});
        }
      }
    }
    return out;
  }

  void _commit() {
    widget.controller.commitTemplates(widget.configKey, values);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Str.t(widget.titleKey)),
            for (var i = 0; i < values.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        TextField(
                          key: Key('tpl:${widget.configKey}:$i:name'),
                          decoration: InputDecoration(
                              labelText:
                                  Str.t('tpl_name', {'n': i + 1})),
                          controller: TextEditingController(
                              text: values[i]['name']),
                          onChanged: (v) => values[i]['name'] = v,
                        ),
                        TextField(
                          key: Key('tpl:${widget.configKey}:$i:text'),
                          decoration: InputDecoration(
                              labelText: Str.t('tpl_text')),
                          controller: TextEditingController(
                              text: values[i]['text']),
                          maxLines: 2,
                          onChanged: (v) => values[i]['text'] = v,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: Str.t('delete'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => values.removeAt(i));
                      _commit();
                    },
                  ),
                ],
              ),
            TextButton(
              onPressed: () {
                setState(
                    () => values.add({'name': '', 'text': ''}));
                _commit();
              },
              child: Text('+ ${Str.t('add')}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings screen: grouped side nav + one section at a time.
/// Port of views/settings/*.
class SettingsView extends StatelessWidget {
  final SettingsController controller;
  final bool narrow;
  final String platform;
  final VoidCallback? onChanged;

  const SettingsView({
    super.key,
    required this.controller,
    this.narrow = false,
    this.platform = '',
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final here = controller.sectionsHere(platform: platform);
    var section = controller.settingsSection;
    if (!here.any((s) => s.$1 == section)) section = 'accounts';
    final labelKey = here.firstWhere((s) => s.$1 == section,
        orElse: () => here.first).$2;
    if (narrow && !controller.settingsOpen) {
      return ListView(
        children: [
          ListTile(title: Text(Str.t('settings_title'))),
          _nav(context, here),
        ],
      );
    }
    final body = _section(context, section);
    if (narrow) {
      return ListView(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: Str.t('settings_title'),
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  controller.closeSettingsSection();
                  onChanged?.call();
                },
              ),
              Expanded(child: Text(Str.t(labelKey))),
            ],
          ),
          ...body,
        ],
      );
    }
    return Column(
      children: [
        ListTile(title: Text(Str.t('settings_title'))),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 210,
                  child: SingleChildScrollView(child: _nav(context, here))),
              const VerticalDivider(width: 1),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(title: Text(Str.t(labelKey))),
                    ...body,
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _nav(
      BuildContext context, List<(String, String)> here) {
    final labels = {for (final s in here) s.$1: s.$2};
    final items = <Widget>[];
    for (final group in SettingsController.navGroups) {
      final ids = group.$2.where(labels.containsKey).toList();
      if (ids.isEmpty) continue;
      if (items.isNotEmpty) items.add(const SizedBox(height: 8));
      items.add(Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Text(Str.t(group.$1)),
      ));
      for (final id in ids) {
        final active =
            controller.settingsSection == id && !narrow;
        items.add(ListTile(
          title: Text(Str.t(labels[id]!)),
          selected: active,
          onTap: () {
            controller.setSettingsSection(id);
            onChanged?.call();
          },
        ));
      }
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }

  List<Widget> _section(BuildContext context, String section) {
    switch (section) {
      case 'limits':
        return _limits();
      case 'calendar':
        return _calendar();
      case 'alarm':
        return _alarm();
      case 'templates':
        return _templates();
      case 'rules':
        return _rules(context);
      case 'browser':
        return _browser(context);
      case 'appearance':
        return _appearance(context);
      case 'ai':
        return _ai();
      case 'advanced':
        return _advanced();
      case 'notifications':
        return _notifications();
      case 'diagnostics':
        return _diagnostics();
      case 'accounts':
      default:
        return _accounts();
    }
  }

  // -- accounts -------------------------------------------------------------------
  List<Widget> _accounts() {
    final c = controller;
    final bPassSet = '${c.get('bakalari_password', '')}'.isNotEmpty;
    final sPassSet = '${c.get('strava_password', '')}'.isNotEmpty;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(Str.t('account_bakalari')),
              AutosaveField(
                  controller: c,
                  label: Str.t('bakalari_url'),
                  draftKey: 'acc:bakalari_url',
                  configKey: 'bakalari_url',
                  fallback: '${c.get('bakalari_url', '')}'),
              Text(Str.t('bakalari_url_hint')),
              AutosaveField(
                  controller: c,
                  label:
                      "${Str.t('account_bakalari')} — ${Str.t('username')}",
                  draftKey: 'acc:bakalari_username',
                  configKey: 'bakalari_username',
                  fallback: '${c.get('bakalari_username', '')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Str.t('account_bakalari')} — ${Str.t('password')}",
                  draftKey: 'acc:bakalari_password',
                  configKey: 'bakalari_password',
                  password: true,
                  hint: bPassSet
                      ? Str.t('password_saved_hint')
                      : Str.t('secret_empty')),
              const Divider(),
              Text(Str.t('account_strava')),
              AutosaveField(
                  controller: c,
                  label: Str.t('strava_url'),
                  draftKey: 'acc:strava_url',
                  configKey: 'strava_url',
                  fallback: '${c.get('strava_url', 'https://strava.cz')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Str.t('account_strava')} — ${Str.t('username')}",
                  draftKey: 'acc:strava_username',
                  configKey: 'strava_username',
                  fallback: '${c.get('strava_username', '')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Str.t('account_strava')} — ${Str.t('password')}",
                  draftKey: 'acc:strava_password',
                  configKey: 'strava_password',
                  password: true,
                  hint: sPassSet
                      ? Str.t('password_saved_hint')
                      : Str.t('secret_empty')),
              AutosaveField(
                  controller: c,
                  label: Str.t('canteen_id'),
                  draftKey: 'acc:strava_canteen_id',
                  configKey: 'strava_canteen_id',
                  fallback: '${c.get('strava_canteen_id', '')}'),
              Text(Str.t('canteen_id_hint')),
              SwitchListTile(
                title: Text(Str.t('use_strava')),
                value: c.get('use_strava', true) == true,
                onChanged: (v) =>
                    c.saveQuiet({'use_strava': v}),
              ),
            ],
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
              onPressed: () {},
              child: Text(Str.t('test_bakalari'))),
          OutlinedButton(
              onPressed: () {},
              child: Text(Str.t('test_strava'))),
        ],
      ),
    ];
  }

  // -- limits ----------------------------------------------------------------------
  List<Widget> _limits() {
    final c = controller;
    double? num_(String raw) {
      try {
        return double.parse(raw.replaceAll(',', '.'));
      } catch (_) {
        return null;
      }
    }

    final subjects = () {
      final raw = c.get('absence', {});
      if (raw is Map) return raw.keys.map((k) => '$k').toList()..sort();
      return <String>[];
    }();
    final limits = c.get('subject_limits', {});
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              AutosaveField(
                controller: c,
                label: Str.t('default_limit'),
                draftKey: 'lim:default',
                configKey: 'absence_critical_pct',
                fallback: '${c.get('absence_critical_pct', 25.0)}',
                parse: (raw) => num_(raw) ?? 25.0,
              ),
              AutosaveField(
                controller: c,
                label: Str.t('warn_limit'),
                draftKey: 'lim:warn',
                configKey: 'absence_warn_pct',
                fallback: '${c.get('absence_warn_pct', 15.0)}',
                parse: (raw) => num_(raw) ?? 15.0,
              ),
              AutosaveField(
                controller: c,
                label: Str.t('reserve_limit'),
                draftKey: 'lim:reserve',
                configKey: 'absence_plan_reserve_pct',
                fallback:
                    '${c.get('absence_plan_reserve_pct', 10.0)}',
                parse: (raw) {
                  final v = num_(raw) ?? 10.0;
                  return v.clamp(0.0, 99.9);
                },
              ),
              Text(Str.t('reserve_hint')),
              for (final subject in subjects)
                AutosaveField(
                  key: Key('lim:subj:$subject'),
                  controller: c,
                  label: subject,
                  draftKey: 'lim:subj:$subject',
                  configKey: 'subject_limits:$subject',
                  fallback: limits is Map
                      ? '${limits[subject] ?? ''}'
                      : '',
                  parse: (raw) => raw.trim().isEmpty
                      ? '__blank__'
                      : num_(raw),
                  onSaved: (v) {
                    final current = Map.of(
                        c.get('subject_limits', {}) ?? {});
                    if (v == '__blank__') {
                      current.remove(subject);
                    } else {
                      current[subject] = v;
                    }
                    c.saveQuiet({'subject_limits': current});
                  },
                ),
              Text(Str.t('limit_subject_hint')),
            ],
          ),
        ),
      ),
    ];
  }

  // -- calendar ----------------------------------------------------------------------
  List<Widget> _calendar() {
    final c = controller;
    final days = c.userFreeDays();
    days.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                decoration:
                    InputDecoration(labelText: Str.t('cal_preset')),
                initialValue: 'custom',
                items: const [
                  DropdownMenuItem(
                      value: 'custom', child: Text('Vlastní')),
                ],
                onChanged: (v) =>
                    c.save({'school_preset_id': v ?? 'custom'}),
              ),
              AutosaveField(
                controller: c,
                label: Str.t('cal_sem1'),
                draftKey: 'cal:sem1',
                configKey: 'sem1_close',
                fallback: '${c.get('sem1_close', '')}',
                parse: (raw) {
                  final cleaned = raw.trim();
                  if (cleaned.isNotEmpty &&
                      c.parseCzDate(cleaned) == null) {
                    throw FormatException('bad date');
                  }
                  return cleaned;
                },
              ),
              AutosaveField(
                controller: c,
                label: Str.t('cal_sem2'),
                draftKey: 'cal:sem2',
                configKey: 'sem2_close',
                fallback: '${c.get('sem2_close', '')}',
                parse: (raw) {
                  final cleaned = raw.trim();
                  if (cleaned.isNotEmpty &&
                      c.parseCzDate(cleaned) == null) {
                    throw FormatException('bad date');
                  }
                  return cleaned;
                },
              ),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(Str.t('cal_free_days')),
              AutosaveField(
                  controller: c,
                  label: Str.t('cal_date'),
                  draftKey: 'cal:add_date',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Str.t('cal_label'),
                  draftKey: 'cal:add_label',
                  configKey: '',
                  draftOnly: true),
              FilledButton(
                key: const Key('cal:add_single'),
                onPressed: () => c.addSingleDay(),
                child: Text(Str.t('cal_add_single')),
              ),
              const Divider(),
              AutosaveField(
                  controller: c,
                  label: Str.t('cal_from'),
                  draftKey: 'cal:from_',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Str.t('cal_to'),
                  draftKey: 'cal:to',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Str.t('cal_label'),
                  draftKey: 'cal:range_label',
                  configKey: '',
                  draftOnly: true),
              FilledButton(
                key: const Key('cal:add_range'),
                onPressed: () => c.addDayRange(),
                child: Text(Str.t('cal_add_range')),
              ),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (days.isEmpty) Text(Str.t('cal_no_days')),
              // Consecutive days with the same label form one grouped
              // row with one delete button (like the Python timeline).
              for (final group in _groupDays(days))
                ListTile(
                  title: Text(group.$1),
                  subtitle: group.$2.isEmpty ? null : Text(group.$2),
                  trailing: IconButton(
                    tooltip: Str.t('delete'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      for (final d in group.$3) {
                        c.deleteFreeDay(d);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  /// Groups consecutive free days with the same label into
  /// (title, label, [dateKeys]) ranges.
  static List<(String, String, List<String>)> _groupDays(
      List<Map<String, String>> days) {
    final parsed = <(DateTime, String, String)>[];
    final fmt = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$');
    for (final d in days) {
      final m = fmt.firstMatch('${d['date']}');
      if (m == null) continue;
      try {
        parsed.add((
          DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
              int.parse(m.group(1)!)),
          '${d['date']}',
          d['label'] ?? ''
        ));
      } catch (_) {}
    }
    parsed.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(String, String, List<String>)>[];
    List<(DateTime, String, String)>? current;
    for (final p in parsed) {
      final last = current == null || current.isEmpty ? null : current.last;
      if (last != null &&
          p.$1.difference(last.$1).inDays == 1 &&
          p.$3 == last.$3) {
        current!.add(p);
      } else {
        current = [p];
        out.add(('', '', []));
      }
      final idx = out.length - 1;
      final keys = [for (final x in current) x.$2];
      final label = current.first.$3;
      final title = current.length == 1
          ? current.first.$2
          : '${current.first.$2} – ${current.last.$2} · '
              '${Str.t('cal_range_days', {'n': current.length})}';
      out[idx] = (title, label, keys);
    }
    return out;
  }

  // -- alarm --------------------------------------------------------------------------
  List<Widget> _alarm() {
    final c = controller;
    if (!c.wakeupAvailable) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(Str.t('wakeup_title')),
                Text(Str.t('wakeup_unavailable')),
              ],
            ),
          ),
        ),
      ];
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(Str.t('wakeup_title')),
              SwitchListTile(
                title: Text(Str.t('wakeup_enable')),
                value: c.get('wakeup_enabled', false) == true,
                onChanged: (v) =>
                    c.save({'wakeup_enabled': v}),
              ),
              AutosaveField(
                controller: c,
                label: Str.t('wakeup_minutes'),
                draftKey: 'rule:wakeup_min',
                configKey: 'wakeup_minutes_before',
                fallback: '${c.get('wakeup_minutes_before', 60)}',
                parse: (raw) {
                  final v =
                      double.tryParse(raw.replaceAll(',', '.'));
                  if (v == null) {
                    throw FormatException('bad number');
                  }
                  return v.toInt().clamp(5, 240);
                },
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // -- templates -----------------------------------------------------------------------
  List<Widget> _templates() {
    final c = controller;
    return [
      TemplateEditor(
          controller: c,
          configKey: 'late_income_excuses',
          titleKey: 'tpl_late'),
      TemplateEditor(
          controller: c,
          configKey: 'left_soon_excuses',
          titleKey: 'tpl_soon'),
      TemplateEditor(
          controller: c,
          configKey: 'short_absence_excuses',
          titleKey: 'tpl_short'),
      TemplateEditor(
          controller: c,
          configKey: 'long_absence_excuses',
          titleKey: 'tpl_long'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AutosaveField(
              controller: c,
              label: Str.t('signature'),
              draftKey: 'tpl:your_signature',
              configKey: 'your_signature',
              fallback: '${c.get('your_signature', '')}'),
        ),
      ),
    ];
  }

  // -- automation rules ------------------------------------------------------------------
  List<Widget> _rules(BuildContext context) {
    final c = controller;
    const modes = ['auto', 'confirm', 'dry_run'];
    String modeLabel(String m) => Str.t(
        {'auto': 'mode_auto', 'confirm': 'mode_confirm', 'dry_run': 'mode_dry_run'}[m]!);
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(Str.t('automation_disclaimer')),
              SwitchListTile(
                key: const Key('rule:pause'),
                title: Text(Str.t('automation_pause')),
                value: c.automationPaused(),
                onChanged: (v) {
                  c.setAutomationPaused(v);
                  onChanged?.call();
                },
              ),
              Text(Str.t('automation_pause_hint')),
              DropdownButtonFormField<String>(
                key: const Key('rule:excuse_mode'),
                decoration: InputDecoration(
                    labelText: Str.t('excuse_mode_label')),
                initialValue: '${c.get('excuse_mode', 'confirm')}',
                items: [
                  for (final m in modes)
                    DropdownMenuItem(value: m, child: Text(modeLabel(m))),
                ],
                onChanged: (v) {
                  final r = c.commitMode(
                      'excuse_mode', v ?? 'confirm', 'confirm');
                  if (r == 'cancelled') {
                    appSnack(context, Str.t('saved'));
                  }
                  onChanged?.call();
                },
              ),
              DropdownButtonFormField<String>(
                key: const Key('rule:order_mode'),
                decoration: InputDecoration(
                    labelText: Str.t('order_mode_label')),
                initialValue: '${c.get('strava_order_mode', 'confirm')}',
                items: [
                  for (final m in modes)
                    DropdownMenuItem(value: m, child: Text(modeLabel(m))),
                ],
                onChanged: (v) {
                  c.commitMode(
                      'strava_order_mode', v ?? 'confirm', 'confirm');
                  onChanged?.call();
                },
              ),
              Text(Str.t('automation_modes_hint')),
              AutosaveField(
                key: const Key('rule:interval'),
                controller: c,
                label: Str.t('check_interval'),
                draftKey: 'rule:interval',
                configKey: 'check_interval_minutes',
                fallback: '${c.get('check_interval_minutes', 60)}',
                parse: (raw) {
                  try {
                    return (double.parse(raw.replaceAll(',', '.')))
                        .toInt()
                        .clamp(1, 1 << 30);
                  } catch (_) {
                    throw FormatException('bad number');
                  }
                },
              ),
              AutosaveField(
                controller: c,
                label: Str.t('excuse_delay'),
                draftKey: 'rule:delay',
                configKey: 'excuse_delay_days',
                fallback: '${c.get('excuse_delay_days', 2)}',
                parse: (raw) {
                  try {
                    return (double.parse(raw.replaceAll(',', '.')))
                        .toInt()
                        .clamp(0, 1 << 30);
                  } catch (_) {
                    throw FormatException('bad number');
                  }
                },
              ),
              AutosaveField(
                controller: c,
                label: Str.t('go_back_weeks'),
                draftKey: 'rule:goback',
                configKey: 'go_back_weeks',
                fallback: '${c.get('go_back_weeks', 4)}',
                parse: (raw) {
                  try {
                    return (double.parse(raw.replaceAll(',', '.')))
                        .toInt()
                        .clamp(0, 1 << 30);
                  } catch (_) {
                    throw FormatException('bad number');
                  }
                },
              ),
              AutosaveField(
                controller: c,
                label: Str.t('go_forward_weeks'),
                draftKey: 'rule:goforward',
                configKey: 'go_forward_weeks',
                fallback: '${c.get('go_forward_weeks', 1)}',
                parse: (raw) {
                  try {
                    return (double.parse(raw.replaceAll(',', '.')))
                        .toInt()
                        .clamp(0, 1 << 30);
                  } catch (_) {
                    throw FormatException('bad number');
                  }
                },
              ),
              AutosaveField(
                key: const Key('rule:cutoff'),
                controller: c,
                label: Str.t('lunch_cutoff_label'),
                draftKey: 'rule:cutoff',
                configKey: 'lunch_order_cutoff_time',
                fallback:
                    '${c.get('lunch_order_cutoff_time', '')}',
                hint: Str.t('lunch_cutoff_hint'),
                parse: (raw) {
                  final cleaned = raw.trim();
                  if (cleaned.isNotEmpty &&
                      !SettingsController.isValidCutoff(cleaned)) {
                    throw FormatException(
                        Str.t('lunch_cutoff_invalid'));
                  }
                  return cleaned;
                },
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // -- browser / background ----------------------------------------------------------------
  List<Widget> _browser(BuildContext context) {
    final c = controller;
    if (platform == 'android') {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(Str.t('run_in_background')),
                  value: c.get('run_in_background', true) == true,
                  onChanged: (v) =>
                      c.saveQuiet({'run_in_background': v}),
                ),
                Text(Str.t('run_in_background_hint')),
              ],
            ),
          ),
        ),
      ];
    }
    if (c.storeManaged) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(Str.t('autostart_store_managed')),
                OutlinedButton(
                    onPressed: () {},
                    child:
                        Text(Str.t('autostart_open_settings'))),
              ],
            ),
          ),
        ),
      ];
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: StatefulBuilder(
            builder: (ctx, setState) {
              var on = c.readAutostart();
              return Column(
                children: [
                  SwitchListTile(
                    key: const Key('browser:autostart'),
                    title: Text(Str.t('autostart')),
                    value: on,
                    onChanged: (v) {
                      if (c.toggleAutostart(v)) {
                        setState(() => on = v);
                      } else {
                        // Rejected: the switch keeps the old state.
                        setState(() {});
                        appSnack(ctx, Str.t('autostart_failed'));
                      }
                    },
                  ),
                  SwitchListTile(
                    title: Text(Str.t('minimize_to_tray')),
                    value: c.get('minimize_to_tray', true) == true,
                    onChanged: (v) =>
                        c.saveQuiet({'minimize_to_tray': v}),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ];
  }

  // -- appearance ------------------------------------------------------------------------------
  List<Widget> _appearance(BuildContext context) {
    final c = controller;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                    labelText:
                        '${Str.t('theme_dark')} / ${Str.t('theme_light')}'),
                initialValue: '${c.get('theme', 'dark')}',
                items: const [
                  DropdownMenuItem(
                      value: 'dark', child: Text('Tmavý')),
                  DropdownMenuItem(
                      value: 'light', child: Text('Světlý')),
                ],
                onChanged: (v) => c.save({'theme': v ?? 'dark'}),
              ),
              DropdownButtonFormField<String>(
                decoration:
                    InputDecoration(labelText: Str.t('language')),
                initialValue: Str.language,
                items: const [
                  DropdownMenuItem(
                      value: 'cs', child: Text('Čeština')),
                  DropdownMenuItem(
                      value: 'en', child: Text('English')),
                ],
                onChanged: (v) {
                  if (v != null) Str.language = v;
                  onChanged?.call();
                },
              ),
              SwitchListTile(
                title: Text(
                    "${Str.t('density')} (${Str.t('density_compact')})"),
                value: c.get('compact_density', false) == true,
                onChanged: (v) =>
                    c.save({'compact_density': v}),
              ),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(Str.t('tutorials')),
              Text(Str.t('tutorials_hint')),
              SwitchListTile(
                title: Text(Str.t('tutorials_toggle')),
                value: c.get('tutorials_enabled', true) == true,
                onChanged: (v) =>
                    c.save({'tutorials_enabled': v}),
              ),
              OutlinedButton(
                onPressed: () {
                  if (c.save(
                      {'tutorials_done': [], 'tutorials_enabled': true})) {
                    appSnack(context, Str.t('tutorials_replayed'));
                  } else {
                    appSnack(context, Str.t('save_failed'));
                  }
                },
                child: Text(Str.t('tutorials_replay')),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // -- AI ------------------------------------------------------------------------------------------------
  List<Widget> _ai() {
    final c = controller;
    final hasKey = '${c.get('gemini_api_key', '')}'.isNotEmpty;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              AutosaveField(
                  controller: c,
                  label: Str.t('gemini_key'),
                  draftKey: 'ai:key',
                  configKey: 'gemini_api_key',
                  password: true,
                  hint: hasKey
                      ? Str.t('key_saved_hint')
                      : Str.t('secret_empty')),
              Text(Str.t('ai_key_steps')),
              AutosaveField(
                  controller: c,
                  label: Str.t('gemini_model'),
                  draftKey: 'ai:model',
                  configKey: 'gemini_model',
                  fallback:
                      '${c.get('gemini_model', 'gemini-3.8-flash')}'),
              Text(Str.t('ai_model_hint')),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(Str.t('ai_auto_enable')),
                value: c.get('gemini_auto_enabled', false) == true,
                onChanged: (v) =>
                    c.saveQuiet({'gemini_auto_enabled': v}),
              ),
              Text(Str.t('ai_auto_hint')),
              AutosaveField(
                  controller: c,
                  label: Str.t('ai_prompt'),
                  draftKey: 'ai:prompt',
                  configKey: 'gemini_prompt',
                  fallback: '${c.get('gemini_prompt', '')}',
                  multiline: true,
                  hint: Str.t('ai_prompt_hint')),
              AutosaveField(
                controller: c,
                label: Str.t('ai_interval'),
                draftKey: 'ai:interval',
                configKey: 'gemini_interval_days',
                fallback: '${c.get('gemini_interval_days', 2)}',
                hint: Str.t('ai_interval_hint'),
                parse: (raw) {
                  final v =
                      int.tryParse(raw.replaceAll(',', '.'));
                  if (v == null) {
                    throw FormatException('bad number');
                  }
                  return v.clamp(1, 30);
                },
              ),
            ],
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
              onPressed: () {},
              child: Text(Str.t('wiz_test_key'))),
          if (hasKey)
            OutlinedButton(
              onPressed: () {
                c.save({
                  'gemini_api_key': '',
                  'gemini_api_key_encrypted': false
                });
                c.clearDrafts('ai:');
                onChanged?.call();
              },
              child: Text(Str.t('delete')),
            ),
        ],
      ),
    ];
  }

  // -- advanced -------------------------------------------------------------------------------
  List<Widget> _advanced() {
    final c = controller;
    double? fnum(String raw) {
      try {
        return double.parse(raw.replaceAll(',', '.'));
      } catch (_) {
        return null;
      }
    }

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              AutosaveField(
                  controller: c,
                  label: Str.t('cache_ttl'),
                  draftKey: 'adv:ttl',
                  configKey: 'cache_ttl_hours',
                  fallback: '${c.get('cache_ttl_hours', 24)}',
                  parse: (raw) => fnum(raw) ?? 24.0),
              AutosaveField(
                  controller: c,
                  label: Str.t('timeout_page'),
                  draftKey: 'adv:page_to',
                  configKey: 'page_load_timeout_s',
                  fallback:
                      '${c.get('page_load_timeout_s', 60.0)}',
                  parse: (raw) => fnum(raw) ?? 60.0),
              const Divider(),
              AutosaveField(
                  controller: c,
                  label: Str.t('log_file'),
                  draftKey: 'adv:log_file',
                  configKey: 'log_file',
                  fallback: '${c.get('log_file', './log.txt')}'),
              AutosaveField(
                  controller: c,
                  label: Str.t('blacklist_file'),
                  draftKey: 'adv:blacklist',
                  configKey: 'strava_blacklist',
                  fallback:
                      '${c.get('strava_blacklist', './strava_blacklist.json')}'),
            ],
          ),
        ),
      ),
    ];
  }

  // -- notifications ----------------------------------------------------------------------------
  List<Widget> _notifications() {
    final c = controller;
    final prefs =
        Map.of(c.get('notifications', {}) ?? {});
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              for (final event in kNotificationEvents)
                SwitchListTile(
                  key: Key('notif:$event'),
                  title: Text(event),
                  value: (prefs[event] ?? true) == true,
                  onChanged: (v) {
                    prefs[event] = v;
                    c.saveQuiet(
                        {'notifications': Map.of(prefs)});
                    onChanged?.call();
                  },
                ),
            ],
          ),
        ),
      ),
    ];
  }

  // -- diagnostics ---------------------------------------------------------------------------------
  List<Widget> _diagnostics() {
    final c = controller;
    final problems = <String>[];
    // Minimal validation: empty keys / bad reserve type surface here.
    for (final key in c.config.keys) {
      if (key.isEmpty) {
        problems.add('bad key: (empty)');
      }
    }
    final reserve = c.get('absence_plan_reserve_pct');
    if (reserve != null) {
      if (reserve is num) {
        if (reserve < 0) problems.add('absence_plan_reserve_pct');
      } else {
        problems.add('absence_plan_reserve_pct');
      }
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (problems.isNotEmpty) ...[
                Text(Str.t('config_problems')),
                for (final p in problems)
                  Text('• $p',
                      style: const TextStyle(color: Colors.red)),
              ] else
                Text(Str.t('config_ok'),
                    style: const TextStyle(color: Colors.green)),
              const Divider(),
              Text(
                  '${Str.t('app_version')} ${c.get('app_version', '')}'),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                    labelText: Str.t('update_channel')),
                initialValue: c.updateChannel,
                items: [
                  DropdownMenuItem(
                      value: 'stable',
                      child:
                          Text(Str.t('update_channel_stable'))),
                  DropdownMenuItem(
                      value: 'beta',
                      child: Text(Str.t('update_channel_beta'))),
                ],
                onChanged: (v) {
                  if (v != null) c.updateChannel = v;
                  onChanged?.call();
                },
              ),
              Text(Str.t('update_channel_hint')),
              Text(
                  '${Str.t('cache_info')} ${c.get('cache_info', '')}'),
              OutlinedButton(
                  onPressed: () {},
                  child: Text(Str.t('clear_cache'))),
            ],
          ),
        ),
      ),
    ];
  }
}
