import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import '../../platform/android/android_channel.dart';

import '../common/app_tokens.dart';
import 'wizard_controller.dart';
import 'wizard_view.dart';

/// Builds selectable [CalendarPreset] cards from `school_presets`.
List<CalendarPreset> buildCalendarPresets([String? language]) {
  String lang = language ?? 'cs';
  try {
    if (language == null) lang = core.getLanguage();
  } catch (_) {}
  final out = <CalendarPreset>[];
  for (final (pid, title) in core.presetOptions(lang)) {
    final (closesA, closesB) = core.presetCloses(pid);
    final daysMap = core.presetDays(pid);
    final sortedDays = daysMap.keys.toList()..sort();
    final counts = <String, int>{};
    for (final d in sortedDays) {
      final lbl = (daysMap[d] ?? '').trim();
      final key = lbl.isEmpty ? '—' : lbl;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    out.add(CalendarPreset(
      id: pid,
      title: title,
      closesA: closesA,
      closesB: closesB,
      totalDays: daysMap.length,
      groups: [
        for (final e in counts.entries) (label: e.key, count: e.value),
      ],
      endText: closesB,
      custom: false,
    ));
  }
  out.add(CalendarPreset(
    id: core.customId,
    title: Strings.get('wiz_cal_custom'),
    custom: true,
  ));
  return out;
}

/// Bridges the shared [AppState] into a [WizardController] for
/// [WizardView].
WizardController wizardControllerFor(AppState s) {
  String lang = 'cs';
  try {
    lang = core.getLanguage();
  } catch (_) {}

  late final WizardController c;
  c = WizardController(
    config: Map<String, Object?>.of(s.config.data),
    onSave: (updates) => s.save(updates),
    onSaveQuiet: (updates) => s.saveQuiet(updates),
    onTestRequest: (service, overrides) {
      s.testConnection(
        service,
        Map<String, Object?>.of(overrides),
        (ok, msg) {
          final err = c.recordTestResult(service, ok, msg);
          if (err == null) {
            c.consumeAutoAdvance(c.step, service);
          }
        },
      );
    },
    onFinishRefresh: () => s.startRefresh(),
    onRequestNotificationPermission: () async {
      s.notificationPermissionAsked = true;
      await const AndroidChannel().requestNotificationPermission();
    },
    onSetLanguage: (l) => s.setLanguage(l),
    onDraftChanged: (key, value) => s.setDraft(key, value),
    onClearDrafts: (prefix) => s.clearDrafts(prefix),
    onStepChanged: (step) => s.wizardGoto(step, WizardController.stepDone),
    onFinished: () => s.wizardFinished(),
    onVerified: (service, fp) {
      s.wizardVerified[service] = fp;
    },
  );
  c.step = s.wizardStep;
  c.dismissed = s.wizardDismissed;
  c.isAndroid = Platform.isAndroid;
  c.testing = s.testing.isEmpty ? null : s.testing;
  c.lastTest = Map<String, Object?>.of(s.lastTest);
  c.verified.addAll(s.wizardVerified);
  c.drafts.addAll(s.drafts);
  c.schoolOptions = core.schoolGroups(lang);
  c.calendarOptions = buildCalendarPresets(lang);

  return c;
}

/// Live first-run setup wizard wired to [appStateProvider].
class LiveWizardView extends ConsumerStatefulWidget {
  final AppTokens? tokens;
  final bool narrow;

  const LiveWizardView({
    super.key,
    this.tokens,
    this.narrow = false,
  });

  @override
  ConsumerState<LiveWizardView> createState() => _LiveWizardViewState();
}

class _LiveWizardViewState extends ConsumerState<LiveWizardView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appStateProvider).wizardOpened();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStateProvider);
    final tok = widget.tokens ?? s.appTokens;
    if (s.wizardDismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/today');
      });
      return Scaffold(
        backgroundColor: tok.bg,
        body: const SizedBox.shrink(),
      );
    }
    final controller = wizardControllerFor(s);
    return WizardView(
      controller: controller,
      tokens: tok,
      narrow: widget.narrow,
    );
  }
}
