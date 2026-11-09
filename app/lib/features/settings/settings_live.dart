import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import 'settings_controller.dart';
import 'settings_view.dart';

/// Injectable OS autostart hooks (wired by desktop autostart in phase 7).
bool Function()? liveAutostartEnabled;
bool Function(bool wanted)? liveSetAutostart;

/// Bridges the shared [AppState] into a [SettingsController] for
/// [SettingsView].
SettingsController settingsControllerFor(AppState s) {
  final cfg = Map<String, dynamic>.of(s.config.data);
  final abs = s.absence();
  final allowed = s.limitSubjects();
  cfg['absence'] = {
    for (final subj in (allowed ?? abs.keys)) subj: abs[subj] ?? 0.0,
  };
  cfg['app_version'] = core.getCurrentVersion();
  cfg['cache_info'] = s.updatedLabel;

  bool storeManaged = false;
  try {
    storeManaged = core.isStorePackage();
  } catch (_) {}

  final c = SettingsController(
    cfg,
    persist: (updates) => s.save(Map<String, Object?>.of(updates)),
    persistQuiet: (updates) => s.saveQuiet(Map<String, Object?>.of(updates)),
    onDraftChanged: (key, value) => s.setDraft(key, value),
    onClearDrafts: (prefix) => s.clearDrafts(prefix),
    onSetSection: (section) => s.setSettingsSection(section),
    onCloseSection: () => s.closeSettingsSection(),
    onTestConnection: (service, overrides) =>
        s.testConnection(service, overrides),
    onSetUpdateChannel: (channel) => s.setUpdateChannel(channel),
    onClearCache: () {
      try {
        final f = File(core.resolvePath(core.cacheFile));
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        return false;
      }
      s.reloadCache();
      return true;
    },
    validateConfig: () => s.config.validate(),
    autostartEnabled: liveAutostartEnabled,
    setAutostart: liveSetAutostart,
    storeManaged: storeManaged,
    isAndroid: Platform.isAndroid,
    wakeupAvailable: s.wakeupAvailable,
  );
  c.drafts.addAll(s.drafts);
  c.settingsSection = s.settingsSection;
  c.settingsOpen = s.settingsOpen;
  c.testing = s.testing;
  c.lastTest = Map<String, dynamic>.of(s.lastTest);
  c.updateChannel = s.updateChannel;
  return c;
}

/// Live settings screen wired to [appStateProvider].
class LiveSettingsView extends ConsumerStatefulWidget {
  final bool narrow;

  const LiveSettingsView({super.key, this.narrow = false});

  @override
  ConsumerState<LiveSettingsView> createState() => _LiveSettingsViewState();
}

class _LiveSettingsViewState extends ConsumerState<LiveSettingsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appStateProvider).tutorialOffer('settings');
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStateProvider);
    final controller = settingsControllerFor(s);
    final platform = Platform.isAndroid
        ? 'android'
        : (Platform.isIOS ? 'ios' : '');
    return SettingsView(
      controller: controller,
      narrow: widget.narrow,
      platform: platform,
      onChanged: () => ref.read(appStateProvider.notifier).emit(),
    );
  }
}
