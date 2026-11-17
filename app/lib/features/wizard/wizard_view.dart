import '../../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../widgets/app_widgets.dart' as w;
import '../common/app_tokens.dart';
import '../settings/settings_view.dart' show TemplateGroupsList;
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
  int _lastStep = 0;
  bool _goingBack = false;

  WizardController get controller => widget.controller;
  AppTokens get tokens => widget.tokens;
  bool get narrow => widget.narrow;

  @override
  void initState() {
    super.initState();
    _lastStep = controller.step.clamp(0, WizardController.stepDone);
    controller.addListener(_onControllerChanged);
    _welcomeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didUpdateWidget(covariant WizardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastStep = widget.controller.step.clamp(0, WizardController.stepDone);
      _goingBack = false;
    }
  }

  void _onControllerChanged() {
    final next = controller.step.clamp(0, WizardController.stepDone);
    if (next != _lastStep) {
      _goingBack = next < _lastStep;
      _lastStep = next;
    }
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
    controller.removeListener(_onControllerChanged);
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

  Widget _stepSwitcher(BuildContext context, int step, Widget child) {
    final noAnim = MediaQuery.disableAnimationsOf(context);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: noAnim ? Duration.zero : const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.topCenter,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        ),
        transitionBuilder: (child, animation) {
          if (noAnim) return child;
          final dx = _goingBack ? -0.08 : 0.08;
          final offset = Tween<Offset>(
            begin: Offset(dx, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: KeyedSubtree(
          key: ValueKey('wiz_step_$step'),
          child: child,
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = controller;
    final t = tokens;
    final step = c.step.clamp(0, WizardController.stepDone);

    final shown = c.shownSteps();
    final stepPos = shown.where((x) => x <= step).length;
    final primaryLabel = step < WizardController.stepDone
        ? c.nextLabel()
        : Strings.get('wiz_finish');
    final VoidCallback? primaryPressed = step < WizardController.stepDone
        ? (c.nextEnabled ? () => _next(context) : null)
        : () => _next(context);

    if (narrow) {
      final heading = _stepHeading(step);
      final bodyChildren =
          _stepContent(context, step, includeHeading: false);
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              Strings.format('wiz_step_of', {
                'i': stepPos,
                'n': shown.length,
              }),
              style: TextStyle(color: t.muted, fontSize: t.fsSmall),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: shown.isEmpty ? 0 : stepPos / shown.length,
                minHeight: 5,
                backgroundColor: t.border,
                color: t.accent,
              ),
            ),
            if (heading != null) ...[
              const SizedBox(height: 12),
              _h(heading, 20),
            ],
          ],
        ),
      );
      final bottomBar = Material(
        key: const Key('wiz:bottom_bar'),
        color: t.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
          child: Row(
            children: [
              if (step > 0) ...[
                TextButton(
                  key: const Key('wiz:back_btn'),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: c.pressBack,
                  child: Text(Strings.get('wiz_back'),
                      maxLines: 1, softWrap: false),
                ),
                const SizedBox(width: 4),
              ],
              if (step < WizardController.stepDone && c.canSkip) ...[
                TextButton(
                  key: const Key('wiz:skip_btn'),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: c.pressSkip,
                  child: Text(Strings.get('wiz_skip'),
                      maxLines: 1, softWrap: false),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: FilledButton(
                  key: const Key('wiz:next_btn'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: primaryPressed,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(primaryLabel, maxLines: 1, softWrap: false),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return Material(
        color: t.bg,
        child: AnimatedPadding(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Divider(height: 1, color: t.border),
                Expanded(
                  child: _stepSwitcher(
                    context,
                    step,
                    SingleChildScrollView(
                      key: ValueKey('wiz_scroll_$step'),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: bodyChildren,
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, color: t.border),
                bottomBar,
              ],
            ),
          ),
        ),
      );
    }

    final content = _stepContent(context, step);
    final dots = Wrap(
      spacing: 6,
      children: [
        for (final i in shown)
          _dot(i < step ? 'ok' : (i == step ? 'working' : 'idle')),
      ],
    );

    final nav = <Widget>[];
    if (step > 0) {
      nav.add(TextButton(
          key: const Key('wiz:back_btn'),
          onPressed: c.pressBack,
          child: Text(Strings.get('wiz_back'))));
    }
    nav.add(const Spacer());
    if (step < WizardController.stepDone && c.canSkip) {
      nav.add(TextButton(
          key: const Key('wiz:skip_btn'),
          onPressed: c.pressSkip,
          child: Text(Strings.get('wiz_skip'))));
    }
    nav.add(FilledButton(
      key: const Key('wiz:next_btn'),
      onPressed: primaryPressed,
      child: Text(primaryLabel),
    ));

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
                      'i': stepPos,
                      'n': shown.length,
                    }),
                    style:
                        TextStyle(color: t.muted, fontSize: t.fsSmall)),
                const SizedBox(height: 8),
                dots,
                const Divider(height: 24),
                if (scrollBody)
                  Flexible(
                    child: _stepSwitcher(
                      context,
                      step,
                      SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: content,
                        ),
                      ),
                    ),
                  )
                else
                  _stepSwitcher(
                    context,
                    step,
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: content,
                    ),
                  ),
                const Divider(height: 24),
                LayoutBuilder(
                  builder: (context, footerConstraints) {
                    final items = [
                      for (final w in nav)
                        if (w is! Spacer) w
                    ];
                    if (footerConstraints.maxWidth < 560 && items.length > 1) {
                      return Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: items,
                      );
                    }
                    return Row(children: nav);
                  },
                ),
              ],
            ),
          ),
        );
    return Container(
      color: t.bg,
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        // Top of the page (`MainAxisAlignment.START` in Python), centred
        // sideways.
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            // Python: ResponsiveRow col {xs: 12, md: 9, lg: 7, xl: 6, xxl: 5}
            // (Flet breakpoints 768 / 992 / 1200 / 1400), centered.
            width: constraints.maxWidth *
                _wizardColumns(constraints.maxWidth + 48) /
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

  String? _stepHeading(int step) {
    switch (step) {
      case WizardController.stepSchool:
        return Strings.get('wiz_cal_h');
      case WizardController.stepBakalari:
        return Strings.get('wiz_bakalari_h');
      case WizardController.stepStrava:
        return Strings.get('wiz_strava_h');
      case WizardController.stepExcuses:
        return Strings.get('wiz_excuses_h');
      case WizardController.stepPhone:
        return Strings.get('wiz_phone_h');
      case WizardController.stepDone:
        return Strings.get('wiz_done_h');
      default:
        return null;
    }
  }

  List<Widget> _stepContent(BuildContext context, int step,
      {bool includeHeading = true}) {
    final c = controller;
    switch (step) {
      case WizardController.stepWelcome:
        return _welcomeContent();
      case WizardController.stepSchool:
        return _schoolContent(includeHeading: includeHeading);
      case WizardController.stepBakalari:
        return [
          if (includeHeading) _h(Strings.get('wiz_bakalari_h'), 19),
          _p(Strings.get('wiz_bakalari_p')),
          const SizedBox(height: 16),
          if (!c.showBakalariUrlField)
            _prefillRow(
              key: const Key('wiz:change_bakalari_url'),
              text: Strings.format('wiz_prefill_school',
                  {'host': _displayHost(c.presetBakalariUrl())}),
              onChange: () {
                c.setDraftSilent('wiz:bakalari_url', c.presetBakalariUrl());
                c.setDraft('wiz:edit_bakalari_url', '1');
              },
            )
          else
            _field(Strings.get('bakalari_url'), 'wiz:bakalari_url',
                c.effectiveBakalariUrl(),
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
          if (includeHeading) _h(Strings.get('wiz_strava_h'), 19),
          _p(Strings.get('wiz_strava_p')),
          const SizedBox(height: 16),
          SwitchListTile(
            value: enabled,
            contentPadding: EdgeInsets.zero,
            title: Text(Strings.get('use_strava')),
            onChanged: c.setStravaEnabled,
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            if (!c.showStravaCanteenField)
              _prefillRow(
                key: const Key('wiz:change_strava_canteen'),
                text: Strings.format(
                    'wiz_prefill_canteen', {'id': c.presetCanteenId()}),
                onChange: () {
                  c.setDraftSilent(
                      'wiz:strava_canteen_id', c.presetCanteenId());
                  c.setDraft('wiz:edit_strava_canteen', '1');
                },
              )
            else
              _field(Strings.get('canteen_id'), 'wiz:strava_canteen_id',
                  c.effectiveCanteenId(),
                  hint: Strings.get('canteen_id_hint')),
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
            ..._testRows('strava'),
          ],
        ];
      case WizardController.stepExcuses:
        return [
          if (includeHeading) ...[
            _h(Strings.get('wiz_excuses_h'), 19),
            const SizedBox(height: 16),
          ],
          _field(Strings.get('wiz_signature_label'), 'wiz:signature',
              '${c.config['your_signature'] ?? ''}',
              hint: Strings.get('signature_hint')),
          _hint(Strings.get('wiz_excuses_p')),
          const SizedBox(height: 12),
          ExpansionTile(
            key: const Key('wiz:excuses_advanced'),
            initiallyExpanded: false,
            maintainState: true,
            tilePadding: EdgeInsets.zero,
            title: Text(Strings.get('sec_advanced')),
            children: [
              TemplateGroupsList(
                readTemplates: (key) => c.config[key] ?? const <Object?>[],
                commitTemplates: (key, values) =>
                    c.saveTemplateList(key, values),
              ),
            ],
          ),
        ];
      case WizardController.stepPhone:
        return _phoneContent(includeHeading: includeHeading);
      default:
        return [
          if (includeHeading) _h(Strings.get('wiz_done_h'), 19),
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

  List<Widget> _schoolContent({bool includeHeading = true}) {
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
      if (includeHeading) _h(Strings.get('wiz_cal_h'), 19),
      _p(Strings.get('wiz_cal_p')),
      const SizedBox(height: 16),
      narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  cards[i],
                  if (i != cards.length - 1) const SizedBox(height: 12),
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

  List<Widget> _phoneContent({bool includeHeading = true}) {
    final c = controller;
    return [
      if (includeHeading) ...[
        _h(Strings.get('wiz_phone_h'), 19),
        const SizedBox(height: 6),
      ],
      _p(Strings.get('wiz_phone_p')),
      const SizedBox(height: 16),
      SwitchListTile(
        value: c.alarmEnabled,
        contentPadding: EdgeInsets.zero,
        title: Text(Strings.get('wakeup_enable')),
        onChanged: c.setAlarmEnabled,
      ),
    ];
  }

  static String _displayHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    }
    return url.replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
  }

  Widget _prefillRow({
    required Key key,
    required String text,
    required VoidCallback onChange,
  }) {
    final t = tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: t.text,
                    fontSize: t.fsBody,
                    fontWeight: FontWeight.w500)),
          ),
          TextButton(
            key: key,
            onPressed: onChange,
            child: Text(Strings.get('wiz_prefill_change')),
          ),
        ],
      ),
    );
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
      padding: const EdgeInsets.only(bottom: 12),
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
