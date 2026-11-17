import '../../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../widgets/app_widgets.dart' as w;
import '../common/app_tokens.dart';
import '../settings/settings_view.dart' show TemplateEditor;
import 'wizard_controller.dart';

/// Placeholder welcome logo (app icon in an accent badge) so a dedicated logo
/// asset can later replace it in one place.
class WelcomeLogo extends StatelessWidget {
  final AppTokens tokens;
  final double size;

  const WelcomeLogo({
    super.key,
    required this.tokens,
    this.size = 72,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.16),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tintColor(t.accent, 0.16),
        border: Border.all(color: tintColor(t.accent, 0.45), width: 1.5),
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/tray-icon.png',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Icon(
            Icons.school_outlined,
            size: size * 0.5,
            color: t.accent,
          ),
        ),
      ),
    );
  }
}

/// First-run setup wizard.
///
/// Steps: welcome (+ language & disclaimer), school, Bakaláři login, Strava
/// login, excuses, phone (Android only), done. Credential steps run a live
/// test on Continue and advance only on success.
class WizardView extends StatefulWidget {
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
  State<WizardView> createState() => _WizardViewState();
}

class _WizardViewState extends State<WizardView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _welcomeCtrl;
  bool _welcomeStarted = false;

  WizardController get controller => widget.controller;
  AppTokens get tokens => widget.tokens;
  bool get narrow => widget.narrow;

  @override
  void initState() {
    super.initState();
    _welcomeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_welcomeStarted) return;
    _welcomeStarted = true;
    if (MediaQuery.disableAnimationsOf(context) ||
        controller.step != WizardController.stepWelcome) {
      _welcomeCtrl.value = 1.0;
    } else {
      _welcomeCtrl.forward();
    }
  }

  @override
  void dispose() {
    _welcomeCtrl.dispose();
    super.dispose();
  }

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
    if (step > 0) {
      nav.add(TextButton(
          onPressed: c.pressBack,
          child: Text(Strings.get('wiz_back'))));
    }
    nav.add(const Spacer());
    if (step < WizardController.stepDone) {
      if (c.canSkip) {
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

    Widget buildCard(bool scrollBody) => Card(
      color: t.card,
      // `components.card`: a 1 px outline in the border colour.
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd),
          side: BorderSide(color: t.border)),
      child: Padding(
        padding: EdgeInsets.all(t.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            if (scrollBody)
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: content,
                  ),
                ),
              )
            else
              ...content,
            const Divider(height: 24),
            if (narrow)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nav.last,
                  if (nav.length > 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
      child: LayoutBuilder(
        // Top of the page (`MainAxisAlignment.START` in Python), centred
        // sideways.
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            // Python: ResponsiveRow col {xs: 12, md: 9, lg: 7, xl: 6, xxl: 5}
            // (Flet breakpoints 768 / 992 / 1200 / 1400), centered.
            width: constraints.maxWidth *
                _wizardColumns(constraints.maxWidth + (narrow ? 16 : 48)) /
                12,
            child: constraints.hasBoundedHeight
                ? buildCard(true)
                : ListView(
                    shrinkWrap: true,
                    children: [buildCard(false)],
                  ),
          ),
        ),
      ),
    );
  }

  /// Twelfths of the page the wizard card takes (`views/wizard.py`).
  static int _wizardColumns(double pageWidth) {
    if (pageWidth >= 1400) return 5;
    if (pageWidth >= 1200) return 6;
    if (pageWidth >= 992) return 7;
    if (pageWidth >= 768) return 9;
    return 12;
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
        color = t.yellow;
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

  Widget _welcomeSlide(double begin, double end, Widget child) {
    final fade = CurvedAnimation(
      parent: _welcomeCtrl,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.16),
      end: Offset.zero,
    ).animate(fade);
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: child),
    );
  }

  List<Widget> _welcomeContent() {
    final c = controller;
    final t = tokens;
    final lang = '${c.config['language'] ?? 'cs'}';
    final logoFade = CurvedAnimation(
      parent: _welcomeCtrl,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    final logoScale = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _welcomeCtrl,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
      ),
    );
    return [
      Center(
        child: FadeTransition(
          opacity: logoFade,
          child: ScaleTransition(
            scale: logoScale,
            child: WelcomeLogo(tokens: t),
          ),
        ),
      ),
      const SizedBox(height: 16),
      _welcomeSlide(0.42, 0.76, _h(Strings.get('wiz_welcome_h'), 22)),
      const SizedBox(height: 6),
      _welcomeSlide(0.55, 0.88, _p(Strings.get('wiz_welcome_p'))),
      const SizedBox(height: 16),
      _welcomeSlide(
        0.65,
        0.95,
        Wrap(
          spacing: 8,
          children: [
            lang != 'cs'
                ? w.GhostButton(
                    label: 'Čeština',
                    tok: t,
                    onPressed: () => c.onSetLanguage('cs'))
                : w.PrimaryButton(
                    label: 'Čeština', tok: t, onPressed: () {}),
            lang != 'en'
                ? w.GhostButton(
                    label: 'English',
                    tok: t,
                    onPressed: () => c.onSetLanguage('en'))
                : w.PrimaryButton(
                    label: 'English', tok: t, onPressed: () {}),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _welcomeSlide(
        0.72,
        1.0,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Strings.get('wiz_disclaimer_p'),
                style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: c.disclaimerOk,
              activeColor: t.accent,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(Strings.get('wiz_disclaimer_ack')),
              onChanged: (v) => c.setDisclaimer(v ?? false),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _stepContent(BuildContext context, int step) {
    final c = controller;
    switch (step) {
      case WizardController.stepWelcome:
        return _welcomeContent();
      case WizardController.stepSchool:
        return _schoolContent();
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
      case WizardController.stepStrava:
        final enabled = c.stravaEnabled;
        return [
          _h(Strings.get('wiz_strava_h'), 19),
          _p(Strings.get('wiz_strava_p')),
          SwitchListTile(
            value: enabled,
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
      case WizardController.stepPhone:
        return _alarmContent();
      default:
        return [
          _h(Strings.get('wiz_done_h'), 19),
          _p(Strings.get('wiz_done_p')),
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

  List<Widget> _schoolContent() {
    final c = controller;
    final t = tokens;
    final selectedGroup = c.selectedSchoolGroup();
    final pickedPreset = c.calPreset();

    Widget schoolCard(core.SchoolGroup group) {
      final isSelected = selectedGroup == group.name;
      final multi = group.presets.length > 1;
      final hasPreset =
          pickedPreset.isNotEmpty && group.presets.any((p) => p.id == pickedPreset);
      return SizedBox(
        width: narrow ? null : 280,
        child: Material(
          color: t.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusMd),
            side: BorderSide(
                color: isSelected ? t.accent : t.border,
                width: isSelected ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('school:${group.name}'),
            onTap: () => c.selectSchoolGroup(group.name),
            child: Padding(
              padding: EdgeInsets.all(t.pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(group.name,
                            style: TextStyle(
                                color: t.text, fontWeight: FontWeight.bold)),
                      ),
                      Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: isSelected ? t.accent : t.faint,
                        size: 20,
                      ),
                    ],
                  ),
                  if (isSelected && multi) ...[
                    const SizedBox(height: 8),
                    RadioGroup<String>(
                      groupValue: hasPreset ? pickedPreset : null,
                      onChanged: (v) {
                        if (v != null) c.selectSchoolPreset(v);
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final opt in group.presets)
                            RadioListTile<String>(
                              key: ValueKey('preset:${opt.id}'),
                              value: opt.id,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              activeColor: t.accent,
                              title: Text(opt.category,
                                  style: TextStyle(
                                      color: t.text, fontSize: t.fsSmall)),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (isSelected && hasPreset) ...[
                    const SizedBox(height: 6),
                    Text(Strings.get('wiz_school_preset_p'),
                        style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget customCard() {
      final isSelected = selectedGroup == core.customId;
      return SizedBox(
        width: narrow ? null : 280,
        child: Material(
          color: t.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusMd),
            side: BorderSide(
                color: isSelected ? t.accent : t.border,
                width: isSelected ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('school:custom'),
            onTap: () => c.selectSchoolGroup(core.customId),
            child: Padding(
              padding: EdgeInsets.all(t.pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(Strings.get('wiz_cal_custom'),
                            style: TextStyle(
                                color: t.text, fontWeight: FontWeight.bold)),
                      ),
                      Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: isSelected ? t.accent : t.faint,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(Strings.get('wiz_cal_custom_p'),
                      style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final cards = [
      for (final g in c.schoolOptions) schoolCard(g),
      customCard(),
    ];
    return [
      _h(Strings.get('wiz_cal_h'), 19),
      _p(Strings.get('wiz_cal_p')),
      const SizedBox(height: 8),
      narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  cards[i],
                  if (i != cards.length - 1) const SizedBox(height: 8),
                ],
              ],
            )
          : Wrap(spacing: 8, runSpacing: 8, children: cards),
      if (pickedPreset.isEmpty) ...[
        const SizedBox(height: 8),
        _hint(Strings.get('wiz_cal_pick')),
      ],
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
    const entries = [
      ('late_income_excuses', 'tpl_late'),
      ('left_soon_excuses', 'tpl_soon'),
      ('short_absence_excuses', 'tpl_short'),
      ('long_absence_excuses', 'tpl_long'),
    ];
    return [
      for (final (key, titleKey) in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TemplateEditor(
            configKey: key,
            titleKey: titleKey,
            readTemplates: () => c.config[key] ?? const <Object?>[],
            commitTemplates: (values) => c.saveTemplateList(key, values),
          ),
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
      key: ValueKey('draft:$key'),
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
    super.key,
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
  late final FocusNode _focus;
  bool _hidden = true;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
    _focus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _DraftField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.password != oldWidget.password) {
      _hidden = true;
    }
    if (!_focus.hasFocus &&
        widget.initial != oldWidget.initial &&
        _ctrl.text != widget.initial) {
      _ctrl.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        obscureText: widget.password && _hidden,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText:
              widget.hint.isEmpty ? null : widget.hint,
          isDense: true,
          filled: true,
          fillColor: widget.tokens.surface,
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
        onChanged: widget.onChanged,
      ),
    );
  }
}
