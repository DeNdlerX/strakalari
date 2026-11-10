import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../common/app_tokens.dart';
import 'wizard_controller.dart';

/// First-run setup wizard — port of `views/wizard.py`.
///
/// Full-screen card with a step indicator: welcome, disclaimer,
/// Bakaláři login, subject limits, Strava login, AI key, school
/// calendar, wake-up alarm (Android only), excuses, done. Credential
/// steps run a live test on Continue and advance only on success.
/// Stateless; state lives in [WizardController] via
/// [ListenableBuilder].
class WizardView extends StatelessWidget {
  final WizardController controller;
  final AppTokens tokens;
  final bool narrow;

  const WizardView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final c = controller;
    final t = tokens;
final step = c.step.clamp(0, WizardController.stepDone);

    // The subjects are loading: stay here (Skip still leaves).
    if (step == WizardController.stepLimits && c.limitsNeedsRefresh) {
      c.markLimitsRefreshStarted();
      c.onLimitsRefresh();
    }

    final content = _stepContent(context, step);
    final shown = c.shownSteps();
    final dots = Wrap(
      spacing: 6,
      children: [
        for (final i in shown)
          _dot(i < step
              ? 'ok'
              : (i == step ? 'working' : 'idle')),
      ],
    );

    final nextLabel = c.nextLabel();
    final nav = <Widget>[];
    if (step > 0 &&
        !(step == WizardController.stepLimits &&
            c.refreshRunning)) {
      nav.add(TextButton(
          onPressed: c.pressBack,
          child: Text(Strings.get('wiz_back'))));
    }
    nav.add(const Spacer());
    if (step < WizardController.stepDone) {
      if (step != WizardController.stepWelcome &&
          step != WizardController.stepDisclaimer) {
        nav.add(TextButton(
            onPressed: c.pressSkip,
            child: Text(Strings.get('wiz_skip'))));
      }
      nav.add(ElevatedButton(
        onPressed: c.nextEnabled ? () => _next(context) : null,
        child: Text(nextLabel),
      ));
    } else {
      nav.add(ElevatedButton(
        onPressed: () => _next(context),
        child: Text(Strings.get('wiz_finish')),
      ));
    }

    final card = Card(
      color: t.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd)),
      child: Padding(
        padding: EdgeInsets.all(t.pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                Strings.format('wiz_step_of', {
                  'i': shown.where((x) => x <= step).length,
                  'n': shown.length,
                }),
                style:
                    TextStyle(color: t.muted, fontSize: t.fsSmall)),
            const SizedBox(height: 8),
            dots,
            const Divider(height: 24),
            ...content,
            const Divider(height: 24),
            if (narrow)
              Column(
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: [
                  nav.last,
                  if (nav.length > 1)
                    Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        for (final w in nav
                            .sublist(0, nav.length - 1)
                            .where((w) => w is! Spacer))
                          w,
                      ],
                    ),
                ],
              )
            else
              Row(children: nav),
          ],
        ),
      ),
    );
    return Container(
      color: t.bg,
      padding: EdgeInsets.all(narrow ? 8 : 24),
      child: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: 640),
          child: ListView(
            shrinkWrap: true,
            children: [card],
          ),
        ),
      ),
    );
  }

  void _next(BuildContext context) {
    final c = controller;
    final result = c.pressNext();
    final msg = result.finishedMessage ?? result.snack;
    if (msg != null && msg.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Widget _dot(String kind) {
    final t = tokens;
    final Color color;
    switch (kind) {
      case 'ok':
        color = t.green;
      case 'working':
        color = t.accent;
      default:
        color = t.faint;
    }
    return Container(
        width: 10,
        height: 10,
        decoration:
            BoxDecoration(color: color, shape: BoxShape.circle));
  }

  // -- step content ---------------------------------------------------------------

  List<Widget> _stepContent(BuildContext context, int step) {
    final c = controller;
    final t = tokens;
switch (step) {
      case WizardController.stepWelcome:
        final lang = '${c.config['language'] ?? 'cs'}';
        return [
          _h(Strings.get('wiz_welcome_h'), 22),
          _p(Strings.get('wiz_welcome_p')),
          Wrap(
            spacing: 8,
            children: [
              lang != 'cs'
                  ? OutlinedButton(
                      onPressed: () =>
                          c.onSetLanguage('cs'),
                      child: const Text('Čeština'))
                  : ElevatedButton(
                      onPressed: null,
                      child: const Text('Čeština')),
              lang != 'en'
                  ? OutlinedButton(
                      onPressed: () =>
                          c.onSetLanguage('en'),
                      child: const Text('English'))
                  : ElevatedButton(
                      onPressed: null,
                      child: const Text('English')),
            ],
          ),
        ];
      case WizardController.stepDisclaimer:
        return [
          _h(Strings.get('wiz_disclaimer_h'), 19),
          _p(Strings.get('wiz_disclaimer_p')),
          _p(Strings.get('wiz_disclaimer_rules')),
          CheckboxListTile(
            value: c.disclaimerOk,
            activeColor: t.accent,
            contentPadding: EdgeInsets.zero,
            controlAffinity:
                ListTileControlAffinity.leading,
            title: Text(Strings.get('wiz_disclaimer_ack')),
            onChanged: (v) =>
                c.setDisclaimer(v ?? false),
          ),
        ];
      case WizardController.stepBakalari:
        return [
          _h(Strings.get('wiz_bakalari_h'), 19),
          _p(Strings.get('wiz_bakalari_p')),
          _field(Strings.get('bakalari_url'), 'wiz:bakalari_url',
              '${c.config['bakalari_url'] ?? ''}',
              hint: Strings.get('bakalari_url_hint')),
          _field(Strings.get('username'), 'wiz:bakalari_username',
              '${c.config['bakalari_username'] ?? ''}'),
          _field(
              Strings.get('password'), 'wiz:bakalari_password', '',
              password: true,
              hint: '${c.config['bakalari_password'] ?? ''}'
                      .isNotEmpty
                  ? Strings.get('new_password')
                  : Strings.get('secret_empty')),
          ..._testRows('bakalari'),
        ];
      case WizardController.stepLimits:
        return _limitsContent(context);
      case WizardController.stepStrava:
        final enabled = c.stravaEnabled;
        return [
          _h(Strings.get('wiz_strava_h'), 19),
          _p(Strings.get('wiz_strava_p')),
          SwitchListTile(
            value: enabled,
            activeThumbColor: t.accent,
            contentPadding: EdgeInsets.zero,
            title: Text(Strings.get('use_strava')),
            onChanged: c.setStravaEnabled,
          ),
          if (enabled) ...[
            _field(Strings.get('username'), 'wiz:strava_username',
                '${c.config['strava_username'] ?? ''}'),
            _field(Strings.get('password'),
                'wiz:strava_password', '',
                password: true,
                hint:
                    '${c.config['strava_password'] ?? ''}'
                            .isNotEmpty
                        ? Strings.get('new_password')
                        : Strings.get('secret_empty')),
            _field(
                Strings.get('canteen_id'), 'wiz:strava_canteen_id',
                '${c.config['strava_canteen_id'] ?? ''}',
                hint: Strings.get('canteen_id_hint')),
            ..._testRows('strava'),
          ],
        ];
      case WizardController.stepAi:
        final enabled = c.aiEnabled;
        return [
          _h(Strings.get('wiz_ai_h'), 19),
          _p(Strings.get('wiz_ai_p')),
          SwitchListTile(
            value: enabled,
            activeThumbColor: t.accent,
            contentPadding: EdgeInsets.zero,
            title: Text(Strings.get('wiz_use_ai')),
            onChanged: c.setAiEnabled,
          ),
          if (enabled) ...[
            _field(Strings.get('gemini_key'), 'wiz:ai_key', '',
                password: true,
                hint: '${c.config['gemini_api_key'] ?? ''}'
                        .isNotEmpty
                    ? Strings.get('new_password')
                    : Strings.get('secret_empty')),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: c.onOpenUrl,
                icon: const Icon(
                    Icons.open_in_new, size: 16),
                label: Text(Strings.get('ai_key_link')),
              ),
            ),
            _hint(Strings.get('ai_key_steps')),
            _field(
                Strings.get('gemini_model'), 'wiz:ai_model',
                '${c.config['gemini_model'] ?? 'gemini-3.8-flash'}'),
            _hint(Strings.get('ai_model_hint')),
            ..._testRows('ai'),
          ],
        ];
      case WizardController.stepCalendar:
        return _calendarContent();
      case WizardController.stepAlarm:
        return _alarmContent();
      case WizardController.stepExcuses:
        return [
          _h(Strings.get('wiz_excuses_h'), 19),
          _p(Strings.get('wiz_excuses_p')),
          _field(Strings.get('signature'), 'wiz:signature',
              '${c.config['your_signature'] ?? ''}',
              hint: Strings.get('signature_hint')),
          _hint(Strings.get('wiz_excuses_tpl')),
          ..._templateEditors(context),
        ];
      default:
        return [
          _h(Strings.get('wiz_done_h'), 19),
          _p(Strings.get('wiz_done_p')),
          _hint(Strings.get('wiz_done_next')),
        ];
    }
  }

  List<Widget> _testRows(String service) {
    final c = controller;
    final t = tokens;
if (c.testing == service) {
      return [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: t.accent)),
            const SizedBox(width: 8),
            Text(Strings.get('testing'),
                style: TextStyle(
                    color: t.muted,
                    fontSize: t.fsSmall)),
          ],
        ),
      ];
    }
    final last = c.lastTest;
    if (last['service'] == service && last['at'] != null) {
      final ok = last['ok'] == true;
      final prefix =
          ok ? Strings.get('connection_ok') : Strings.get('connection_failed');
      return [
        Text('$prefix (${last['at']}): ${last['message'] ?? ''}',
            style: TextStyle(
                color: ok ? t.green : t.red,
                fontSize: t.fsSmall)),
      ];
    }
    return [];
  }

  List<Widget> _limitsContent(BuildContext context) {
    final c = controller;
    final t = tokens;
final rows = <Widget>[
      _h(Strings.get('wiz_limits_h'), 19),
      _p(Strings.get('wiz_limits_p')),
    ];
    if (c.refreshRunning) {
      // No inputs while loading: every progress tick rebuilds.
      rows.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: t.accent)),
          const SizedBox(width: 8),
          Text(Strings.get('wiz_limits_loading'),
              style:
                  TextStyle(color: t.muted, fontSize: t.fsSmall)),
        ],
      ));
      if (c.refreshStep.isNotEmpty) {
        rows.add(Text(c.refreshStep,
            style: TextStyle(
                color: t.faint, fontSize: t.fsSmall)));
      }
      return rows;
    }
    final subjects = c.limitSubjects();
    if (subjects.isEmpty) {
      rows.add(_hint(Strings.get('wiz_limits_none')));
      rows.add(Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () {
            c.onLimitsRefresh();
            if (context.mounted &&
                c.refreshRunning == false) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content:
                          Text(Strings.get('already_running'))));
            }
          },
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(Strings.get('wiz_limits_retry')),
        ),
      ));
      return rows;
    }
    final limits =
        (c.config['subject_limits'] as Map?) ?? const {};
    rows.add(_field(Strings.get('default_limit'), 'wiz:limit_default',
        '${c.config['absence_critical_pct'] ?? 25.0}'));
    rows.add(_hint(Strings.get('limit_subject_hint')));
    for (final subject in subjects) {
      rows.add(_field(subject, 'wiz:limit:$subject',
          '${limits[subject] ?? ''}'));
    }
    return rows;
  }

  List<Widget> _calendarContent() {
    final c = controller;
    final t = tokens;
final preset = c.calPreset();
    Widget card(CalendarPreset p) {
      final selected = preset == p.id;
      return InkWell(
        onTap: () => c.setDraft('wiz:cal_preset', p.id),
        borderRadius: BorderRadius.circular(t.radiusMd),
        child: Container(
          width: narrow ? null : 280,
          decoration: BoxDecoration(
            color: t.card,
            border: Border.all(
                color: selected ? t.accent : t.border,
                width: selected ? 2 : 1),
            borderRadius:
                BorderRadius.circular(t.radiusMd),
          ),
          padding: EdgeInsets.all(t.pad),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text(p.title,
                          style: TextStyle(
                              color: t.text,
                              fontWeight: FontWeight.bold))),
                  Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected
                          ? t.accent
                          : t.faint,
                      size: 20),
                ],
              ),
              const SizedBox(height: 4),
              if (!p.custom) ...[
                Text(
                    Strings.format('cal_closes', {
                      'a': p.closesA.isEmpty
                          ? Strings.get('cal_auto')
                          : p.closesA,
                      'b': p.closesB.isEmpty
                          ? Strings.get('cal_auto')
                          : p.closesB,
                    }),
                    style: TextStyle(
                        color: t.muted,
                        fontSize: t.fsSmall)),
                Text(
                    Strings.format('wiz_cal_days', {
                      'n': p.totalDays,
                      'end': p.endText.isEmpty
                          ? Strings.get('cal_auto')
                          : p.endText,
                    }),
                    style: TextStyle(
                        color: t.text,
                        fontSize: t.fsSmall,
                        fontWeight: FontWeight.bold)),
                Text(
                    p.groups
                        .map((g) =>
                            '${g.label} ${g.count}')
                        .join(' · '),
                    style: TextStyle(
                        color: t.muted,
                        fontSize: t.fsSmall)),
                Text(Strings.get('wiz_cal_only_school'),
                    style: TextStyle(
                        color: t.faint,
                        fontSize: t.fsSmall)),
              ] else
                Text(Strings.get('wiz_cal_custom_p'),
                    style: TextStyle(
                        color: t.muted,
                        fontSize: t.fsSmall)),
            ],
          ),
        ),
      );
    }

    final cards = [for (final p in c.calendarOptions) card(p)];
    return [
      _h(Strings.get('wiz_cal_h'), 19),
      _p(Strings.get('wiz_cal_p')),
      narrow
          ? Column(
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  cards[i],
                  if (i != cards.length - 1)
                    const SizedBox(height: 8),
                ],
              ],
            )
          : Wrap(spacing: 8, runSpacing: 8, children: cards),
      if (preset.isEmpty) _hint(Strings.get('wiz_cal_pick')),
    ];
  }

  List<Widget> _alarmContent() {
    final c = controller;
    final t = tokens;
final enabled = c.alarmEnabled;
    final rows = <Widget>[
      _h(Strings.get('wiz_alarm_h'), 19),
      _p(Strings.get('wiz_alarm_p')),
      SwitchListTile(
        value: enabled,
        activeThumbColor: t.accent,
        contentPadding: EdgeInsets.zero,
        title: Text(Strings.get('wakeup_enable')),
        onChanged: c.setAlarmEnabled,
      ),
    ];
    if (enabled) {
      final minutes = c.alarmMinutes() ?? 60;
      rows.add(_field(Strings.get('wakeup_minutes'),
          'wiz:wakeup_minutes', '$minutes'));
      rows.add(_hint(Strings.format('wakeup_hint', {'n': minutes})));
      if (c.alarmExactOff) {
        rows.add(Text(Strings.get('wakeup_exact_off'),
            style: TextStyle(
                color: t.yellow,
                fontSize: t.fsSmall)));
        rows.add(Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: c.onAlarmPermission,
            icon:
                const Icon(Icons.alarm_on, size: 18),
            label: Text(Strings.get('wakeup_exact_allow')),
          ),
        ));
      }
    }
    rows.add(_hint(Strings.get('wiz_alarm_later')));
    return rows;
  }

  List<Widget> _templateEditors(BuildContext context) {
    final c = controller;
    const keys = [
      'late_income_excuses',
      'left_soon_excuses',
      'short_absence_excuses',
      'long_absence_excuses',
    ];
    return [
      for (final key in keys)
        _DraftArea(
          initial: c.excuseTemplates[key] ?? '',
          label: key,
          tokens: tokens,
          onChanged: (v) =>
              c.excuseTemplates[key] = v,
        ),
    ];
  }

  // -- small builders ---------------------------------------------------------------

  Widget _h(String text, double size) {
    final t = tokens;
    return Text(text,
        style: TextStyle(
            color: t.text,
            fontSize: size,
            fontWeight: FontWeight.bold));
  }

  Widget _p(String text) {
    final t = tokens;
    return Text(text,
        style: TextStyle(color: t.muted, fontSize: tokens.fsBody));
  }

  Widget _hint(String text) {
    final t = tokens;
    return Text(text,
        style: TextStyle(color: t.muted, fontSize: t.fsSmall));
  }

  Widget _field(String label, String key, String initial,
      {bool password = false, String hint = ''}) {
    return _DraftField(
      label: label,
      initial: initial,
      password: password,
      hint: hint,
      tokens: tokens,
      onChanged: (v) =>
          controller.setDraftSilent(key, v),
    );
  }
}

/// Text field bound to a wizard draft (writes silently so typing never
/// rebuilds the step and drops focus).
class _DraftField extends StatefulWidget {
  final String label;
  final String initial;
  final bool password;
  final String hint;
  final AppTokens tokens;
  final void Function(String value) onChanged;

  const _DraftField({
    required this.label,
    required this.initial,
    required this.tokens,
    required this.onChanged,
    this.password = false,
    this.hint = '',
  });

  @override
  State<_DraftField> createState() => _DraftFieldState();
}

class _DraftFieldState extends State<_DraftField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _ctrl,
        obscureText: widget.password,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText:
              widget.hint.isEmpty ? null : widget.hint,
          isDense: true,
          filled: true,
          fillColor: widget.tokens.surface,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// Multi-line template editor (one template per line).
class _DraftArea extends StatefulWidget {
  final String initial;
  final String label;
  final AppTokens tokens;
  final void Function(String value) onChanged;

  const _DraftArea({
    required this.initial,
    required this.label,
    required this.tokens,
    required this.onChanged,
  });

  @override
  State<_DraftArea> createState() => _DraftAreaState();
}

class _DraftAreaState extends State<_DraftArea> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _ctrl,
        maxLines: 3,
        minLines: 1,
        decoration: InputDecoration(
          labelText: widget.label,
          isDense: true,
          filled: true,
          fillColor: widget.tokens.surface,
          alignLabelWithHint: true,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
