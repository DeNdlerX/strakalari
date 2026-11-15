import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/wakeup_card.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/common/open_url.dart';
import 'package:app/platform/scheduler_jobs.dart' show checkIntervalMinutes;
import 'package:app/widgets/app_widgets.dart' as w;
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
        appSnack(context, Strings.get('save_failed'));
        return;
      }
    }
    if (!widget.password &&
        SettingsController.sameValue(c.get(widget.configKey), newVal)) {
      c.clearDrafts(widget.draftKey);
      _showValue(newVal);
      return; // focus moved without an edit: nothing to save
    }
    if (!c.saveQuiet({widget.configKey: newVal})) return;
    if (!widget.password) {
      c.clearDrafts(widget.draftKey);
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

  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    // Python `labeled_field`: a fixed caption above the box, the label as
    // the placeholder (a floating label reads as "empty" even when filled).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Text(widget.label,
            style: TextStyle(
                color: tok.text,
                fontSize: tok.fsSmall,
                fontWeight: FontWeight.w700)),
        TextField(
          key: Key('auto:${widget.draftKey}'),
          controller: text,
          focusNode: focus,
          style: TextStyle(color: tok.text, fontSize: tok.fsBody),
          decoration: InputDecoration(
            hintText: widget.hint.isEmpty ? widget.label : widget.hint,
            suffixIcon: widget.password
                ? IconButton(
                    tooltip: '',
                    icon: Icon(_hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hidden = !_hidden),
                  )
                : null,
          ),
          obscureText: widget.password && _hidden,
          minLines: widget.multiline ? 3 : 1,
          maxLines: widget.multiline ? null : 1,
          onChanged: (v) => widget.controller.setDraft(widget.draftKey, v),
          onSubmitted: (_) => _commit(),
        ),
      ],
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

class _TemplateRow {
  final TextEditingController name;
  final TextEditingController text;
  final FocusNode nameFocus;
  final FocusNode textFocus;
  bool disposed = false;

  _TemplateRow(String initialName, String initialText, VoidCallback onBlur)
      : name = TextEditingController(text: initialName),
        text = TextEditingController(text: initialText),
        nameFocus = FocusNode(),
        textFocus = FocusNode() {
    nameFocus.addListener(() {
      if (!nameFocus.hasFocus) onBlur();
    });
    textFocus.addListener(() {
      if (!textFocus.hasFocus) onBlur();
    });
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    name.dispose();
    text.dispose();
    nameFocus.dispose();
    textFocus.dispose();
  }
}

class _TemplateEditorState extends State<TemplateEditor> {
  late List<Map<String, String>> values;
  final List<_TemplateRow> _rows = [];
  final List<_TemplateRow> _pendingDispose = [];
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    values = _load();
    _rebuildRows();
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

  void _rebuildRows() {
    if (_rows.isNotEmpty) {
      _pendingDispose.addAll(_rows);
      _rows.clear();
      _schedulePendingDispose();
    }
    for (var i = 0; i < values.length; i++) {
      _rows.add(_makeRow(values[i]));
    }
  }

  _TemplateRow _makeRow(Map<String, String> item) => _TemplateRow(
        item['name'] ?? '',
        item['text'] ?? '',
        _commitIfDirty,
      );

  void _schedulePendingDispose() {
    if (_pendingDispose.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _flushPendingDispose();
    });
  }

  void _flushPendingDispose() {
    for (final r in _pendingDispose) {
      r.dispose();
    }
    _pendingDispose.clear();
  }

  static bool _sameValues(
      List<Map<String, String>> a, List<Map<String, String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['name'] != b[i]['name'] || a[i]['text'] != b[i]['text']) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(covariant TemplateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = widget.configKey != oldWidget.configKey;
    final anyFocused =
        _rows.any((r) => r.nameFocus.hasFocus || r.textFocus.hasFocus);
    if (!keyChanged && (_dirty || anyFocused)) return;
    final fresh = _load();
    if (keyChanged || !_sameValues(fresh, values)) {
      values = fresh;
      _dirty = false;
      _rebuildRows();
    }
  }

  void _syncFromRows() {
    for (var i = 0; i < _rows.length && i < values.length; i++) {
      values[i]['name'] = _rows[i].name.text;
      values[i]['text'] = _rows[i].text.text;
    }
  }

  void _commitIfDirty() {
    if (!_dirty) return;
    _commit();
  }

  void _commit() {
    _syncFromRows();
    _dirty = false;
    widget.controller.commitTemplates(widget.configKey, values);
  }

  @override
  void dispose() {
    if (_dirty) {
      _syncFromRows();
      _dirty = false;
      widget.controller.commitTemplates(widget.configKey, values);
    }
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();
    _flushPendingDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 20,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(Strings.get(widget.titleKey)),
            for (var i = 0; i < _rows.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      spacing: 12,
                      children: [
                        TextField(
                          key: Key('tpl:${widget.configKey}:$i:name'),
                          decoration: InputDecoration(
                              labelText:
                                  Strings.format('tpl_name', {'n': i + 1})),
                          controller: _rows[i].name,
                          focusNode: _rows[i].nameFocus,
                          onChanged: (v) {
                            values[i]['name'] = v;
                            _dirty = true;
                          },
                          onSubmitted: (_) => _commit(),
                        ),
                        TextField(
                          key: Key('tpl:${widget.configKey}:$i:text'),
                          decoration: InputDecoration(
                              labelText: Strings.get('tpl_text')),
                          controller: _rows[i].text,
                          focusNode: _rows[i].textFocus,
                          keyboardType: TextInputType.multiline,
                          minLines: 2,
                          maxLines: null,
                          onChanged: (v) {
                            values[i]['text'] = v;
                            _dirty = true;
                          },
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: Strings.get('delete'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() {
                        values.removeAt(i);
                        final removed = _rows.removeAt(i);
                        _pendingDispose.add(removed);
                      });
                      _schedulePendingDispose();
                      _commit();
                    },
                  ),
                ],
              ),
            TextButton(
              onPressed: () {
                setState(() {
                  final item = {'name': '', 'text': ''};
                  values.add(item);
                  _rows.add(_makeRow(item));
                });
                _commit();
              },
              child: Text('+ ${Strings.get('add')}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A muted hint line under a field (Python `hint_text`).
/// Port of `_background_overview` (settings/automation.py): a switch per
/// line of the phone's background notification and a preview that follows
/// them in place (no page re-render), its rows with the icons the
/// notification draws (StatusViews.java).
class BackgroundOverview extends StatefulWidget {
  const BackgroundOverview({super.key, required this.controller});
  final SettingsController controller;

  @override
  State<BackgroundOverview> createState() => _BackgroundOverviewState();
}

class _BackgroundOverviewState extends State<BackgroundOverview> {
  static const Map<String, IconData> _icons = {
    'next_lesson': Icons.schedule,
    'lunch': Icons.restaurant,
    'lunch_orders': Icons.shopping_cart_outlined,
    'excuses': Icons.mail_outline,
    'wakeup': Icons.alarm,
  };

  SettingsController get c => widget.controller;

  core.StatusContent? _content() {
    final inputs = c.backgroundStatusInputs;
    if (inputs == null) return null;
    try {
      final n = checkIntervalMinutes(c.get('check_interval_minutes', 60)).toInt();
      return core.buildStatus(inputs(),
          fallback: (
            Strings.get('bg_notif_title'),
            Strings.format('bg_notif_text', {'n': n < 1 ? 1 : n}),
          ));
    } catch (e) {
      // The switches still work.
      // ignore: avoid_print
      print('Warning: notification preview failed (${e.runtimeType}: $e)');
      return null;
    }
  }

  void _toggle(String item, bool on) {
    final items = core.withItem(Map<String, Object?>.of(c.config), item, on);
    if (!c.saveQuiet({'background_notification_items': items})) {
      setState(() {}); // the switch shows the stored state again
      return;
    }
    setState(() {}); // the preview follows in place
  }

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    final picked = core.selectedItems(Map<String, Object?>.of(c.config)).toSet();
    final content = _content();
    final head = [Strings.get('app_title'), content?.sub ?? '']
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final body = <Widget>[];
    if (content != null && content.rows.isNotEmpty) {
      for (final row in content.rows) {
        body.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Icon(_icons[row.kind], size: 16, color: tok.muted),
            Expanded(child: Text(row.line, style: TextStyle(fontSize: tok.fsSmall))),
          ],
        ));
      }
    } else if (content != null) {
      // The plain "running in the background".
      body.add(Text(content.title, style: const TextStyle(fontWeight: FontWeight.bold)));
      if (content.text.isNotEmpty) {
        body.add(Text(content.text, style: TextStyle(fontSize: tok.fsSmall, color: tok.muted)));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tok.gap,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Text(Strings.get('bg_overview_title'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                _Hint(Strings.get('bg_overview_hint')),
                for (final item in core.items)
                  SwitchListTile(
                    key: Key('bg:item:$item'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(Strings.get('bg_item_$item')),
                    value: picked.contains(item),
                    onChanged: (v) => _toggle(item, v),
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              key: const Key('bg:preview'),
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(Strings.get('bg_preview'),
                    style: TextStyle(
                        fontSize: tok.fsSmall, fontWeight: FontWeight.bold, color: tok.muted)),
                Text(head, style: TextStyle(fontSize: tok.fsTiny, color: tok.faint)),
                ...body,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    return Text(text, style: TextStyle(color: tok.faint, fontSize: tok.fsSmall));
  }
}

/// A bold card caption (Python `txt(..., bold=True)`).
class _CardTitle extends StatelessWidget {
  final String text;
  const _CardTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    return Text(text,
        style: TextStyle(
            color: tok.text,
            fontSize: tok.fsBody,
            fontWeight: FontWeight.w700));
  }
}

/// Section icons of the side navigation (Python `SECTION_ICONS`).
const Map<String, IconData> _sectionIcons = {
  'accounts': Icons.person_outline,
  'limits': Icons.percent,
  'calendar': Icons.calendar_month_outlined,
  'alarm': Icons.alarm,
  'templates': Icons.description_outlined,
  'rules': Icons.bolt_outlined,
  'browser': Icons.sync_outlined,
  'appearance': Icons.palette_outlined,
  'ai': Icons.auto_awesome_outlined,
  'advanced': Icons.tune,
  'notifications': Icons.notifications_outlined,
  'diagnostics': Icons.bug_report_outlined,
};

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

  Widget _spaced(Tokens tok, List<Widget> items) => ListView(
        padding: EdgeInsets.zero,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            items[i],
            if (i != items.length - 1) SizedBox(height: tok.gap),
          ],
          SizedBox(height: tok.pad * 2),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    final here = controller.sectionsHere(platform: platform);
    var section = controller.settingsSection;
    if (!here.any((s) => s.$1 == section)) section = 'accounts';
    final labelKey =
        here.firstWhere((s) => s.$1 == section, orElse: () => here.first).$2;
    if (narrow && !controller.settingsOpen) {
      return _spaced(tok, [
        w.HeaderRow(
            heading: Strings.get('settings_title'), updated: '', tok: tok),
        _nav(context, tok, here),
      ]);
    }
    final body = _section(context, section);
    if (narrow) {
      return _spaced(tok, [
        Row(
          spacing: 4,
          children: [
            IconButton(
              tooltip: Strings.get('settings_title'),
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                controller.closeSettingsSection();
                onChanged?.call();
              },
            ),
            Expanded(
              child: Text(Strings.get(labelKey),
                  style: TextStyle(
                      color: tok.text,
                      fontSize: tok.fsTitle,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        ...body,
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tok.gap,
      children: [
        w.HeaderRow(
            heading: Strings.get('settings_title'), updated: '', tok: tok),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              SizedBox(
                  width: 210,
                  child: SingleChildScrollView(
                      child: _nav(context, tok, here))),
              VerticalDivider(width: 1, color: tok.border),
              Expanded(
                child: _spaced(tok, [
                  w.HeaderRow(
                      heading: Strings.get(labelKey), updated: '', tok: tok),
                  ...body,
                ]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _nav(BuildContext context, Tokens tok, List<(String, String)> here) {
    final labels = {for (final s in here) s.$1: s.$2};
    final vpad = narrow ? 14.0 : 8.0; // finger-sized rows on a phone
    final items = <Widget>[];
    for (final group in SettingsController.navGroups) {
      final ids = group.$2.where(labels.containsKey).toList();
      if (ids.isEmpty) continue;
      if (items.isNotEmpty) items.add(const SizedBox(height: 8));
      items.add(Padding(
        padding: const EdgeInsets.only(left: 10, bottom: 2),
        child: w.SectionHeader(Strings.get(group.$1), tok: tok),
      ));
      for (final id in ids) {
        final active = controller.settingsSection == id && !narrow;
        items.add(Tooltip(
          message: Strings.get(labels[id]!),
          child: Material(
            color: active ? tintColor(tok.accent, 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(tok.radiusSm),
            child: InkWell(
              borderRadius: BorderRadius.circular(tok.radiusSm),
              onTap: () {
                controller.setSettingsSection(id);
                onChanged?.call();
              },
              child: Padding(
                padding: EdgeInsets.fromLTRB(10, vpad, 10, vpad),
                child: Row(
                  spacing: 10,
                  children: [
                    Icon(_sectionIcons[id] ?? Icons.circle_outlined,
                        size: 18, color: active ? tok.accent : tok.muted),
                    Expanded(
                      child: Text(Strings.get(labels[id]!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: active ? tok.text : tok.muted,
                              fontSize: tok.fsBody,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
        items.add(const SizedBox(height: 2));
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
        return _ai(context);
      case 'advanced':
        return _advanced();
      case 'notifications':
        return _notifications();
      case 'diagnostics':
        return _diagnostics(context);
      case 'accounts':
      default:
        return _accounts(context);
    }
  }

  Map<String, Object?> _accountOverrides() {
    final c = controller;
    final ov = <String, Object?>{
      'bakalari_url': c.draft('acc:bakalari_url', '${c.get('bakalari_url', '')}'),
      'bakalari_username':
          c.draft('acc:bakalari_username', '${c.get('bakalari_username', '')}'),
      'strava_url': c.draft('acc:strava_url', '${c.get('strava_url', '')}'),
      'strava_username':
          c.draft('acc:strava_username', '${c.get('strava_username', '')}'),
      'strava_canteen_id':
          c.draft('acc:strava_canteen_id', '${c.get('strava_canteen_id', '')}'),
    };
    if (c.draft('acc:bakalari_password').trim().isNotEmpty) {
      ov['bakalari_password'] = c.draft('acc:bakalari_password');
    }
    if (c.draft('acc:strava_password').trim().isNotEmpty) {
      ov['strava_password'] = c.draft('acc:strava_password');
    }
    return ov;
  }

  Widget? _testResultCard(String service) {
    final c = controller;
    if (c.lastTest['service'] != service) return null;
    final ok = c.lastTest['ok'] == true;
    final msg = '${c.lastTest['message'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '${ok ? Strings.get('connection_ok') : Strings.get('connection_failed')} — $msg',
          style: TextStyle(color: ok ? Colors.green : Colors.red),
        ),
      ),
    );
  }

  // -- accounts -------------------------------------------------------------------
  List<Widget> _accounts(BuildContext context) {
    final c = controller;
    final bPassSet = '${c.get('bakalari_password', '')}'.isNotEmpty;
    final sPassSet = '${c.get('strava_password', '')}'.isNotEmpty;
    final bRes = _testResultCard('bakalari');
    final sRes = _testResultCard('strava');
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CardTitle(Strings.get('account_bakalari')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('bakalari_url'),
                  draftKey: 'acc:bakalari_url',
                  configKey: 'bakalari_url',
                  fallback: '${c.get('bakalari_url', '')}'),
              _Hint(Strings.get('bakalari_url_hint')),
              AutosaveField(
                  controller: c,
                  label:
                      "${Strings.get('account_bakalari')} — ${Strings.get('username')}",
                  draftKey: 'acc:bakalari_username',
                  configKey: 'bakalari_username',
                  fallback: '${c.get('bakalari_username', '')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Strings.get('account_bakalari')} — ${Strings.get('password')}",
                  draftKey: 'acc:bakalari_password',
                  configKey: 'bakalari_password',
                  password: true,
                  hint: bPassSet
                      ? Strings.get('password_saved_hint')
                      : Strings.get('secret_empty')),
              const Divider(),
              _CardTitle(Strings.get('account_strava')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('strava_url'),
                  draftKey: 'acc:strava_url',
                  configKey: 'strava_url',
                  fallback: '${c.get('strava_url', 'https://strava.cz')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Strings.get('account_strava')} — ${Strings.get('username')}",
                  draftKey: 'acc:strava_username',
                  configKey: 'strava_username',
                  fallback: '${c.get('strava_username', '')}'),
              AutosaveField(
                  controller: c,
                  label:
                      "${Strings.get('account_strava')} — ${Strings.get('password')}",
                  draftKey: 'acc:strava_password',
                  configKey: 'strava_password',
                  password: true,
                  hint: sPassSet
                      ? Strings.get('password_saved_hint')
                      : Strings.get('secret_empty')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('canteen_id'),
                  draftKey: 'acc:strava_canteen_id',
                  configKey: 'strava_canteen_id',
                  fallback: '${c.get('strava_canteen_id', '')}'),
              _Hint(Strings.get('canteen_id_hint')),
              SwitchListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(Strings.get('use_strava')),
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
              onPressed: () {
                final ok = c.testConnection('bakalari', _accountOverrides());
                appSnack(context, Strings.get(ok ? 'testing' : 'already_running'));
                onChanged?.call();
              },
              child: Text(Strings.get('test_bakalari'))),
          OutlinedButton(
              onPressed: () {
                final ok = c.testConnection('strava', _accountOverrides());
                appSnack(context, Strings.get(ok ? 'testing' : 'already_running'));
                onChanged?.call();
              },
              child: Text(Strings.get('test_strava'))),
        ],
      ),
      ?bRes,
      ?sRes,
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              AutosaveField(
                controller: c,
                label: Strings.get('default_limit'),
                draftKey: 'lim:default',
                configKey: 'absence_critical_pct',
                fallback: '${c.get('absence_critical_pct', 25.0)}',
                parse: (raw) => num_(raw) ?? 25.0,
              ),
              AutosaveField(
                controller: c,
                label: Strings.get('warn_limit'),
                draftKey: 'lim:warn',
                configKey: 'absence_warn_pct',
                fallback: '${c.get('absence_warn_pct', 15.0)}',
                parse: (raw) => num_(raw) ?? 15.0,
              ),
              AutosaveField(
                controller: c,
                label: Strings.get('reserve_limit'),
                draftKey: 'lim:reserve',
                configKey: 'absence_plan_reserve_pct',
                fallback:
                    '${c.get('absence_plan_reserve_pct', 10.0)}',
                parse: (raw) {
                  final v = num_(raw) ?? 10.0;
                  return v.clamp(0.0, 99.9);
                },
              ),
              _Hint(Strings.get('reserve_hint')),
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
              _Hint(Strings.get('limit_subject_hint')),
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              DropdownButtonFormField<String>(
                decoration:
                    InputDecoration(labelText: Strings.get('cal_preset')),
                initialValue: 'custom',
                items: [
                  DropdownMenuItem(
                      value: 'custom', child: Text(Strings.get('cal_custom_opt'))),
                ],
                onChanged: (v) =>
                    c.save({'school_preset_id': v ?? 'custom'}),
              ),
              AutosaveField(
                controller: c,
                label: Strings.get('cal_sem1'),
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
                label: Strings.get('cal_sem2'),
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CardTitle(Strings.get('cal_free_days')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('cal_date'),
                  draftKey: 'cal:add_date',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Strings.get('cal_label'),
                  draftKey: 'cal:add_label',
                  configKey: '',
                  draftOnly: true),
              FilledButton(
                key: const Key('cal:add_single'),
                onPressed: () => c.addSingleDay(),
                child: Text(Strings.get('cal_add_single')),
              ),
              const Divider(),
              AutosaveField(
                  controller: c,
                  label: Strings.get('cal_from'),
                  draftKey: 'cal:from_',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Strings.get('cal_to'),
                  draftKey: 'cal:to',
                  configKey: '',
                  draftOnly: true),
              AutosaveField(
                  controller: c,
                  label: Strings.get('cal_label'),
                  draftKey: 'cal:range_label',
                  configKey: '',
                  draftOnly: true),
              FilledButton(
                key: const Key('cal:add_range'),
                onPressed: () => c.addDayRange(),
                child: Text(Strings.get('cal_add_range')),
              ),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (days.isEmpty) _Hint(Strings.get('cal_no_days')),
              // Consecutive days with the same label form one grouped
              // row with one delete button (like the Python timeline).
              for (final group in groupDays(days))
                ListTile(
                  title: Text(group.$1),
                  subtitle: group.$2.isEmpty ? null : Text(group.$2),
                  trailing: IconButton(
                    tooltip: Strings.get('delete'),
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
  @visibleForTesting
  static List<(String, String, List<String>)> groupDays(
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
          core.daysBetween(last.$1, p.$1) == 1 &&
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
              '${Strings.format('cal_range_days', {'n': current.length})}';
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
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 20,
              children: [
                _CardTitle(Strings.get('wakeup_title')),
                _Hint(Strings.get('wakeup_unavailable')),
              ],
            ),
          ),
        ),
      ];
    }
    return [WakeupCard(controller: c)];
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
              label: Strings.get('signature'),
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
    String modeLabel(String m) => Strings.get({'auto': 'mode_auto', 'confirm': 'mode_confirm', 'dry_run': 'mode_dry_run'}[m]!);
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              _Hint(Strings.get('automation_disclaimer')),
              SwitchListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                key: const Key('rule:pause'),
                title: Text(Strings.get('automation_pause')),
                value: c.automationPaused(),
                onChanged: (v) {
                  c.setAutomationPaused(v);
                  onChanged?.call();
                },
              ),
              _Hint(Strings.get('automation_pause_hint')),
              KeyedSubtree(
                key: ValueKey('tree:rule:excuse_mode:${c.get('excuse_mode', 'confirm')}:${c.modeRevision}'),
                child: DropdownButtonFormField<String>(
                  key: const Key('rule:excuse_mode'),
                  decoration: InputDecoration(
                      labelText: Strings.get('excuse_mode_label')),
                  initialValue: '${c.get('excuse_mode', 'confirm')}',
                  items: [
                    for (final m in modes)
                      DropdownMenuItem(value: m, child: Text(modeLabel(m))),
                  ],
                  onChanged: (v) async {
                    await c.commitMode('excuse_mode', v ?? 'confirm', 'confirm');
                    onChanged?.call();
                  },
                ),
              ),
              KeyedSubtree(
                key: ValueKey('tree:rule:order_mode:${c.get('strava_order_mode', 'confirm')}:${c.modeRevision}'),
                child: DropdownButtonFormField<String>(
                  key: const Key('rule:order_mode'),
                  decoration: InputDecoration(
                      labelText: Strings.get('order_mode_label')),
                  initialValue: '${c.get('strava_order_mode', 'confirm')}',
                  items: [
                    for (final m in modes)
                      DropdownMenuItem(value: m, child: Text(modeLabel(m))),
                  ],
                  onChanged: (v) async {
                    await c.commitMode(
                        'strava_order_mode', v ?? 'confirm', 'confirm');
                    onChanged?.call();
                  },
                ),
              ),
              _Hint(Strings.get('automation_modes_hint')),
              AutosaveField(
                key: const Key('rule:interval'),
                controller: c,
                label: Strings.get('check_interval'),
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
                label: Strings.get('excuse_delay'),
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
                label: Strings.get('go_back_weeks'),
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
                label: Strings.get('go_forward_weeks'),
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
                label: Strings.get('lunch_cutoff_label'),
                draftKey: 'rule:cutoff',
                configKey: 'lunch_order_cutoff_time',
                fallback:
                    '${c.get('lunch_order_cutoff_time', '')}',
                hint: Strings.get('lunch_cutoff_hint'),
                parse: (raw) {
                  final cleaned = raw.trim();
                  if (cleaned.isNotEmpty &&
                      !SettingsController.isValidCutoff(cleaned)) {
                    throw FormatException(
                        Strings.get('lunch_cutoff_invalid'));
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
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 20,
              children: [
                SwitchListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(Strings.get('run_in_background')),
                  value: c.get('run_in_background', true) == true,
                  onChanged: (v) =>
                      c.saveQuiet({'run_in_background': v}),
                ),
                _Hint(Strings.get('run_in_background_hint')),
              ],
            ),
          ),
        ),
        // `_background_overview`: what the background notification shows.
        BackgroundOverview(controller: c),
      ];
    }
    if (c.storeManaged) {
      // StartupTask is owned by Windows (Settings > Apps > Startup); the
      // HKCU Run toggle has no effect inside the MSIX container. The tray
      // switch stays, like Python's form card (autostart, tray).
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 20,
              children: [
                _Hint(Strings.get('autostart_store_managed')),
                OutlinedButton.icon(
                    key: const Key('browser:startup-settings'),
                    onPressed: () => openUrl('ms-settings:startupapps'),
                    icon: const Icon(Icons.open_in_new),
                    label:
                        Text(Strings.get('autostart_open_settings'))),
                SwitchListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(Strings.get('minimize_to_tray')),
                  value: c.get('minimize_to_tray', true) == true,
                  onChanged: (v) => c.saveQuiet({'minimize_to_tray': v}),
                ),
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
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    key: const Key('browser:autostart'),
                    title: Text(Strings.get('autostart')),
                    value: on,
                    onChanged: (v) {
                      if (c.toggleAutostart(v)) {
                        setState(() => on = v);
                      } else {
                        // Rejected: the switch keeps the old state.
                        setState(() {});
                        appSnack(ctx, Strings.get('autostart_failed'));
                      }
                    },
                  ),
                  SwitchListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(Strings.get('minimize_to_tray')),
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                    labelText:
                        '${Strings.get('theme_dark')} / ${Strings.get('theme_light')}'),
                initialValue: '${c.get('theme', 'dark')}',
                items: [
                  DropdownMenuItem(
                      value: 'dark', child: Text(Strings.get('theme_dark'))),
                  DropdownMenuItem(
                      value: 'light', child: Text(Strings.get('theme_light'))),
                ],
                onChanged: (v) => c.save({'theme': v ?? 'dark'}),
              ),
              DropdownButtonFormField<String>(
                decoration:
                    InputDecoration(labelText: Strings.get('language')),
                initialValue: Strings.lang,
                items: [
                  DropdownMenuItem(
                      value: 'cs', child: Text('Čeština')),
                  DropdownMenuItem(
                      value: 'en', child: Text('English')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    Strings.lang = v;
                    c.save({'language': v});
                  }
                  onChanged?.call();
                },
              ),
              SwitchListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(
                    "${Strings.get('density')} (${Strings.get('density_compact')})"),
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CardTitle(Strings.get('tutorials')),
              _Hint(Strings.get('tutorials_hint')),
              SwitchListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(Strings.get('tutorials_toggle')),
                value: c.get('tutorials_enabled', true) == true,
                onChanged: (v) =>
                    c.save({'tutorials_enabled': v}),
              ),
              OutlinedButton(
                onPressed: () {
                  if (c.save(
                      {'tutorials_done': [], 'tutorials_enabled': true})) {
                    appSnack(context, Strings.get('tutorials_replayed'));
                  } else {
                    appSnack(context, Strings.get('save_failed'));
                  }
                },
                child: Text(Strings.get('tutorials_replay')),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // -- AI ------------------------------------------------------------------------------------------------
  List<Widget> _ai(BuildContext context) {
    final c = controller;
    final hasKey = '${c.get('gemini_api_key', '')}'.isNotEmpty;
    final aiRes = _testResultCard('ai');
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              AutosaveField(
                  controller: c,
                  label: Strings.get('gemini_key'),
                  draftKey: 'ai:key',
                  configKey: 'gemini_api_key',
                  password: true,
                  hint: hasKey
                      ? Strings.get('key_saved_hint')
                      : Strings.get('secret_empty')),
              _Hint(Strings.get('ai_key_steps')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('gemini_model'),
                  draftKey: 'ai:model',
                  configKey: 'gemini_model',
                  fallback:
                      '${c.get('gemini_model', 'gemini-3.8-flash')}'),
              _Hint(Strings.get('ai_model_hint')),
            ],
          ),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              SwitchListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(Strings.get('ai_auto_enable')),
                value: c.get('gemini_auto_enabled', false) == true,
                onChanged: (v) =>
                    c.saveQuiet({'gemini_auto_enabled': v}),
              ),
              _Hint(Strings.get('ai_auto_hint')),
              AutosaveField(
                  controller: c,
                  label: Strings.get('ai_prompt'),
                  draftKey: 'ai:prompt',
                  configKey: 'gemini_prompt',
                  fallback: '${c.get('gemini_prompt', '')}',
                  multiline: true,
                  hint: Strings.get('ai_prompt_hint')),
              AutosaveField(
                controller: c,
                label: Strings.get('ai_interval'),
                draftKey: 'ai:interval',
                configKey: 'gemini_interval_days',
                fallback: '${c.get('gemini_interval_days', 2)}',
                hint: Strings.get('ai_interval_hint'),
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
              onPressed: () {
                final ov = <String, Object?>{};
                if (c.draft('ai:key').trim().isNotEmpty) {
                  ov['gemini_api_key'] = c.draft('ai:key');
                }
                final model = c
                    .draft('ai:model',
                        '${c.get('gemini_model', 'gemini-3.8-flash')}')
                    .trim();
                if (model.isNotEmpty) ov['gemini_model'] = model;
                final ok = c.testConnection('ai', ov);
                appSnack(context, Strings.get(ok ? 'testing' : 'already_running'));
                onChanged?.call();
              },
              child: Text(Strings.get('wiz_test_key'))),
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
              child: Text(Strings.get('delete')),
            ),
        ],
      ),
      ?aiRes,
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              AutosaveField(
                  controller: c,
                  label: Strings.get('cache_ttl'),
                  draftKey: 'adv:ttl',
                  configKey: 'cache_ttl_hours',
                  fallback: '${c.get('cache_ttl_hours', 24)}',
                  parse: (raw) => fnum(raw) ?? 24.0),
              AutosaveField(
                  controller: c,
                  label: Strings.get('timeout_page'),
                  draftKey: 'adv:page_to',
                  configKey: 'page_load_timeout_s',
                  fallback:
                      '${c.get('page_load_timeout_s', 60.0)}',
                  parse: (raw) => fnum(raw) ?? 60.0),
              const Divider(),
              AutosaveField(
                  controller: c,
                  label: Strings.get('log_file'),
                  draftKey: 'adv:log_file',
                  configKey: 'log_file',
                  fallback: '${c.get('log_file', './log.txt')}'),
              AutosaveField(
                  controller: c,
                  label: Strings.get('blacklist_file'),
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
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            children: [
              for (final event in kNotificationEvents)
                SwitchListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
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
  List<Widget> _diagnostics(BuildContext context) {
    final c = controller;
    final problems = <String>[];
    if (c.validateConfig != null) {
      try {
        problems.addAll(c.validateConfig!());
      } catch (exc) {
        problems.add('${Strings.get('config_problems')}: $exc'.split('\n').first);
      }
    } else {
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
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              spacing: 20,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (problems.isNotEmpty) ...[
                _CardTitle(Strings.get('config_problems')),
                for (final p in problems)
                  Text('• $p',
                      style: const TextStyle(color: Colors.red)),
              ] else
                Text(Strings.get('config_ok'),
                    style: const TextStyle(color: Colors.green)),
              const Divider(),
              Text(
                  '${Strings.get('app_version')} ${c.get('app_version', '')}'),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                    labelText: Strings.get('update_channel')),
                initialValue: c.updateChannel,
                items: [
                  DropdownMenuItem(
                      value: 'stable',
                      child:
                          Text(Strings.get('update_channel_stable'))),
                  DropdownMenuItem(
                      value: 'beta',
                      child: Text(Strings.get('update_channel_beta'))),
                ],
                onChanged: (v) {
                  if (v != null) {
                    if (!c.changeUpdateChannel(v)) {
                      appSnack(context, Strings.get('save_failed'));
                    }
                  }
                  onChanged?.call();
                },
              ),
              _Hint(Strings.get('update_channel_hint')),
              Text(
                  '${Strings.get('cache_info')} ${c.get('cache_info', '')}'),
              OutlinedButton(
                  onPressed: () {
                    if (c.clearCache()) {
                      appSnack(context, Strings.get('cache_cleared'));
                    } else {
                      appSnack(context, Strings.get('save_failed'));
                    }
                    onChanged?.call();
                  },
                  child: Text(Strings.get('clear_cache'))),
            ],
          ),
        ),
      ),
    ];
  }
}
