// Desktop tray + window + background jobs (one process).
//
// Port of `strakalari/flet_ui/tray.py` and `flet_ui/macos.py` to the
// Flutter one-process model (PLAN §3.2/§3.4):
// * Python runs TWO processes (tray parent + Flet window child), so
//   closing the window never kills automation. Flutter runs ONE: the
//   window hides to the tray (where the user enabled
//   `minimize_to_tray`), and the scheduler lives in the same isolate.
//   Closing the window therefore only hides it; real quit is the tray
//   menu's Quit (or the window close with the toggle off).
// * Autostart launches with `--minimized`: the window starts hidden
//   and only the tray + scheduler run.
// * On macOS the tray can never live in the window process (Cocoa's
//   event loop must run on the main thread — see `macos.py`), so the
//   Flutter window must always hide to the tray there; `hideToTray`
//   defaults to true on macOS regardless of the setting. (The
//   accessory-policy part — no Dock icon — is runner config,
//   `LSUIElement`; see the phase-7 docs note.)
// * Refresh/update scheduling mirrors the tray's `PeriodicRunner`
//   wiring: first auto-run anchored to the last successful refresh
//   (`startupSeed(loadDataCache())`), the interval re-read from the
//   saved config, refresh and update as the two jobs, one toast for a
//   failed job, and a re-entrancy guard so a manual refresh never
//   piles onto a running one. Deviation: the loop is an async
//   `Timer`-based re-implementation here instead of core's
//   `PeriodicRunner`, because `runRefresh` is async and core jobs are
//   sync — the schedule math (`nextDue`) and failure accounting stay
//   the same.
// * The update job is core's `checkForUpdates` + `notifyNewRelease`
//   with the saved channel (same channels, same 24 h cache, same
//   once-per-release toast; silent on Store builds).
//
// The app wires the jobs (refresh needs controllers); this file owns
// the window/tray mechanics and the schedule bookkeeping. Calling
// [DesktopTrayController.initialize] is safe anywhere (tests,
// unsupported platforms): every OS call is guarded.
import 'package:clock/clock.dart';
import 'dart:async';
import 'dart:io';

import 'package:strakalari_core/strakalari_core.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Window title / tray tooltip. Must match the shell's title and the
/// phase-5 stub's `appWindowTitle` (`platform/desktop.dart`).
const String desktopWindowTitle = 'Strakaláři';

/// True where the window process can host its own tray icon
/// (mirrors `macos.embedded_tray_supported`).
bool get embeddedTraySupported => !Platform.isMacOS;

/// True where a normal launch runs the tray, which opens the window
/// (mirrors `macos.tray_hosts_window`). On macOS the window must
/// always hide to the tray instead of quitting.
bool get trayHostsWindow => Platform.isMacOS;

/// Tray-menu labels. Defaults cover cs (the app default) and en; the
/// app passes localized strings from its ARB bundle when available.
class TrayStrings {
  const TrayStrings({
    required this.open,
    required this.refreshNow,
    required this.pause,
    required this.resume,
    required this.quit,
  });

  final String open;
  final String refreshNow;
  final String pause;
  final String resume;
  final String quit;

  static TrayStrings forLanguage(String language) {
    if (language.toLowerCase().startsWith('en')) {
      return const TrayStrings(
        open: 'Open Strakaláři',
        refreshNow: 'Refresh now',
        pause: 'Pause automation',
        resume: 'Resume automation',
        quit: 'Quit',
      );
    }
    return const TrayStrings(
      open: 'Otevřít Strakaláře',
      refreshNow: 'Aktualizovat nyní',
      pause: 'Pozastavit automatiku',
      resume: 'Obnovit automatiku',
      quit: 'Ukončit',
    );
  }
}

/// Window + tray mechanic: hide-to-tray, tray menu, show/quit.
///
/// Distinct from the phase-5 stub (`platform/desktop.dart`): that one
/// records calls for tests, this one drives the real plugins.
class DesktopTrayController with WindowListener, TrayListener {
  DesktopTrayController({
    String? iconPath,
    TrayStrings? strings,
    this.onOpenWindow,
    this.onRefreshNow,
    this.onTogglePause,
    this.onQuit,
    this.isPaused,
    this.hideToTraySetting,
  })  : _iconPath = iconPath ?? 'assets/tray-icon.ico',
        _strings = strings ?? TrayStrings.forLanguage('cs');

  final String _iconPath;
  TrayStrings _strings;
  final Future<void> Function()? onOpenWindow;
  final Future<void> Function()? onRefreshNow;
  final Future<void> Function()? onTogglePause;
  final Future<void> Function()? onQuit;
  final bool Function()? isPaused;
  final bool Function()? hideToTraySetting;

  bool _ready = false;
  bool _quitting = false;

  /// Effective hide-to-tray: forced on macOS (the tray cannot live in
  /// the window process there), otherwise the user's setting.
  bool get hideToTray => trayHostsWindow || (hideToTraySetting?.call() ?? true);

  /// Prepares window + tray hooks. Safe to call anywhere.
  Future<void> initialize({required bool minimized}) async {
    if (_ready) return;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      await trayManager.setIcon(_iconPath);
      await trayManager.setToolTip(desktopWindowTitle);
      trayManager.addListener(this);
      await _rebuildMenu();

      if (minimized) {
        await windowManager.hide();
      } else {
        await showWindow();
      }
      _ready = true;
    } catch (_) {
      // Window hooks are optional (tests, unsupported platforms).
    }
  }

  /// Shows and focuses the window (single-instance signal lands here).
  Future<void> showWindow() async {
    try {
      await onOpenWindow?.call();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  /// Rebuilds the tray menu (call after a language or pause change —
  /// mirrors pystray re-reading the labels on every open).
  Future<void> updateMenu({TrayStrings? strings}) async {
    if (strings != null) _strings = strings;
    await _rebuildMenu();
  }

  Future<void> _rebuildMenu() async {
    try {
      final paused = isPaused?.call() ?? false;
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(
          key: 'show',
          label: _strings.open,
          onClick: (_) => showWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'refresh',
          label: _strings.refreshNow,
          onClick: (_) async {
            try {
              await onRefreshNow?.call();
            } catch (_) {}
          },
        ),
        MenuItem.checkbox(
          key: 'pause',
          label: paused ? _strings.resume : _strings.pause,
          checked: paused,
          onClick: (_) async {
            try {
              await onTogglePause?.call();
            } catch (_) {}
            await _rebuildMenu();
          },
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: _strings.quit,
          onClick: (_) => quit(),
        ),
      ]));
    } catch (_) {}
  }

  /// Real quit from the tray menu (or window close with the toggle
  /// off): stops the loop via [onQuit], drops the icon, exits.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await onQuit?.call();
    } catch (_) {}
    try {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  // -- WindowListener ---------------------------------------------------

  @override
  Future<void> onWindowClose() async {
    if (_quitting || !hideToTray) {
      await quit();
      return;
    }
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  // -- TrayListener ------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_rebuildMenu());
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // Handled by each item's onClick above; kept for the interface.
  }
}

/// Background schedule: refresh + update-check jobs on a timer.
///
/// Mirrors the tray's `PeriodicRunner` wiring (`TrayApp`: jobs
/// `refresh` + `update`, interval re-read from the saved config, the
/// first run anchored to the last successful refresh, re-entrancy
/// guard, one toast per failed job). The actual refresh is injected
/// (it needs the app's controllers); the update check runs core's
/// `checkForUpdates` + `notifyNewRelease` directly.
class DesktopBackgroundLoop {
  DesktopBackgroundLoop({
    required this.refreshJob,
    this.intervalMinutesProvider,
    this.lastRunProvider,
    this.prefsProvider,
    this.updateChannelProvider,
    this.pausedProvider,
    this.updateJob,
    this.onFailure,
    this.afterRun,
  });

  final Future<String> Function() refreshJob;
  final double? Function()? intervalMinutesProvider;
  final DateTime? Function()? lastRunProvider;
  final Map<String, Object?>? Function()? prefsProvider;
  final String Function()? updateChannelProvider;
  final bool Function()? pausedProvider;

  /// The app's update job (Python: `state.start_update_check()`); when
  /// null, [runUpdateJob] asks core directly.
  final Future<String> Function()? updateJob;

  /// The app's failed-job hook (Python: `_on_result`); when null, one
  /// toast per failed job.
  final void Function(String name, Object error)? onFailure;

  /// Called after every run of the jobs (Python: the phone's chained
  /// `_on_result`: re-sync the background, re-arm the wake alarm).
  final void Function()? afterRun;

  /// When the jobs last ran (the anchor of the next due run).
  DateTime? get lastRun => _lastRun;

  Timer? _timer;
  DateTime? _lastRun;
  bool _running = false;
  bool _started = false;

  /// First-run anchor: the last successful refresh from disk (null =
  /// unknown → refresh on start, like Python's `startup_seed`).
  static DateTime? seedFromDisk() {
    try {
      return startupSeed(loadDataCache());
    } catch (_) {
      return null;
    }
  }

  /// Starts the timer loop. The first auto-run comes [intervalMinutes]
  /// after the seeded last run (or fires soon with no/overdue seed).
  void start({DateTime? seedLastRun}) {
    if (_started) return;
    _started = true;
    _lastRun = seedLastRun ?? lastRunProvider?.call();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_tick());
    });
  }

  /// Runs both jobs immediately (tray-menu "Refresh now"): never
  /// touches the periodic timer, like `run_now`.
  Future<void> runNow() => _runJobs();

  /// Stops the timer (quit). Never raises.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  double get _intervalMinutes {
    try {
      final value = intervalMinutesProvider?.call();
      if (value != null && value >= 1.0) return value;
    } catch (_) {}
    return 60.0;
  }

  Future<void> _tick() async {
    try {
      if (pausedProvider?.call() ?? false) return; // Held: fire later.
      // Re-read the live interval (settings are edited in the window).
      final interval = _intervalMinutes;
      final last = _lastRun;
      final now = clock.now();
      final due = last == null || now.difference(last).inSeconds >= interval * 60;
      if (!due || _running) return;
      await _runJobs();
    } catch (_) {}
  }

  Future<void> _runJobs() async {
    // One refresh at a time: a manual run never piles onto a running one.
    if (_running) return; // "skipped (a refresh is already running)"
    _running = true;
    var ok = true;
    try {
      await refreshJob();
    } catch (e) {
      ok = false;
      _reportFailure('refresh', e);
    }
    try {
      await (updateJob ?? runUpdateJob)();
    } catch (e) {
      ok = false;
      _reportFailure('update', e);
    } finally {
      _lastRun = ok
          ? clock.now()
          : clock.now().subtract(
              Duration(seconds: (_intervalMinutes * 60).round() - 300));
      _running = false;
    }
    try {
      afterRun?.call();
    } catch (_) {}
  }

  /// Announces a new release once (GitHub asked at most once a day —
  /// that budget lives in core's `update_cache.json`).
  ///
  /// Returns `update <version> announced` / `no new release to
  /// announce` like Python's `_job_update`.
  Future<String> runUpdateJob() async {
    final channel =
        normalizeChannel(updateChannelProvider?.call() ?? defaultChannel());
    final info = await checkForUpdates(channel: channel);
    if (notifyNewRelease(info, prefsProvider?.call())) {
      return 'update ${info!['version']} announced';
    }
    return 'no new release to announce';
  }

  void _reportFailure(String name, Object error) {
    final hook = onFailure;
    if (hook != null) {
      try {
        hook(name, error);
      } catch (_) {}
      return;
    }
    try {
      notify('refresh_failed', 'job failed: $name',
          prefsProvider?.call());
    } catch (_) {}
  }
}
