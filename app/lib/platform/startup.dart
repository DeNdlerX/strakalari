// Platform start-up: what `main.py`, `flet_ui/app.py` `run()` /
// `run_mobile()` and the platform half of `main(page)` do around the UI.
//
// * Desktop: the OS key store (Python's `keyring`), `--forget-secrets`
//   (the uninstaller), the single-instance guard (`ensure_single_primary`,
//   `mode="ping"` for `--minimized` like the tray), toasts, the tray with
//   hide-to-tray, and the scheduler (`_register_jobs`).
// * Android: the data dir (`getApplicationSupportDirectory()/data`, what
//   Flet set as `FLET_APP_STORAGE_DATA`), the Keystore-wrapped key, the
//   phone bridges, the scheduler, the background service + wake alarm
//   (`_setup_phone_background`) and the hand-off port the headless
//   wake-up uses while the UI is alive.
//
// Deviation (one process, PLAN §3.2): the tray, the window and the
// scheduler live in one process; Python ran a tray parent and a Flet child.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../controllers/app_state.dart';
import '../l10n/strings.dart';
import '../tutorial/tours.dart';
import 'android/android_channel.dart';
import 'android/android_keystore.dart';
import 'android/background.dart';
import 'desktop/keystore_desktop.dart';
import 'desktop/notifications.dart';
import 'desktop/single_instance.dart';
import 'desktop/tray.dart';
import 'scheduler_jobs.dart';

bool get _isPhone => Platform.isAndroid || Platform.isIOS;

/// What [prepareStartup] found out before the UI exists.
class StartupContext {
  const StartupContext({
    this.minimized = false,
    this.guard,
    this.layoutResult,
    this.rootDir,
  });

  /// `--minimized` (autostart): the window starts hidden in the tray.
  final bool minimized;

  /// The single-instance guard, held for the process lifetime.
  final SingleInstance? guard;

  /// Result of `ensureMultiAccountLayout(rootDir)` (§4.1, §4.2).
  final MultiAccountLayoutResult? layoutResult;

  /// Resolved root user data directory.
  final String? rootDir;
}

/// Runs before `runApp`. Exits the process for `--forget-secrets` and for
/// a second launch (after telling the running one to show its window).
Future<StartupContext> prepareStartup(List<String> args) async {
  Strings.isMobile = isMobile();
  if (Platform.isAndroid) {
    final support = await getApplicationSupportDirectory();
    final dataDir = '${support.path}/data';
    await Directory(dataDir).create(recursive: true);
    setMobileDataDir(dataDir);
    // Run the one-time F4 move BEFORE warming all account keys (§4.1).
    final layout = await ensureMultiAccountLayout(
      dataDir,
      warmAndroidRootKey: (r) => warmAndroidRootKeyClean(r),
    );
    if (layout.isReady && layout.registry != null) {
      await warmAndroidKeystoreAll(
        dataDir,
        layout.registry!.accounts.map((a) => a.id),
      );
    } else if (layout.isDegraded) {
      try {
        await warmAndroidKeystore(dataDir);
      } on KeyStoreMissing {
        // No Keystore: the plain file, like Python without pyjnius.
      } on Object catch (e) {
        // ignore: avoid_print
        print('Warning: Keystore warm-up failed (${e.runtimeType}: $e).');
      }
    }
    installAndroidBridges(const AndroidChannel(),
        languageOf: () => Strings.lang);
    // ignore: avoid_print
    print('Info: phone app starting.');
    return StartupContext(layoutResult: layout, rootDir: dataDir);
  }
  if (_isPhone) return const StartupContext();

  keyStoreBackend = const DesktopKeyStore();
  if (args.contains('--forget-secrets')) {
    exit(AccountManager.forgetAllKeys(getUserDataDir()) ? 0 : 1);
  }
  final minimized = launchMinimized(args);
  final rootDir = getUserDataDir();
  SingleInstance? guard;
  try {
    final (status, held) = await ensureSinglePrimary(
        dataDir: rootDir, mode: minimized ? 'ping' : 'show');
    if (status == 'secondary') exit(0);
    guard = held;
  } on Object catch (e) {
    // Never refuse to start over the guard (Python: degraded start).
    // ignore: avoid_print
    print('Warning: single-instance guard failed ($e).');
  }
  // Run the one-time F4 move AFTER single-instance guard and BEFORE AppState (§4.1).
  final layout = await ensureMultiAccountLayout(rootDir);
  return StartupContext(
    minimized: minimized,
    guard: guard,
    layoutResult: layout,
    rootDir: rootDir,
  );
}

/// `main.py`'s routing: `--minimized` (autostart) starts in the tray, any
/// other launch opens the window. One process here, so "the tray" means
/// the window starts hidden.
bool launchMinimized(List<String> args) => args.contains('--minimized');

/// Offers the first-run tour before starting [PhoneBackground] so Android's
/// notification permission prompt waits until the intro tour finishes.
void startPhoneBackground(AppState state, PhoneBackground phone) {
  if (!state.setupPending && state.tutorialOffer(firstTourId)) {
    state.onChanged();
  }
  phone.start();
}

/// Starts the scheduler and the platform services once the UI's state
/// exists. Never throws.
Future<void> startPlatformServices(
    ProviderContainer container, StartupContext ctx) async {
  final state = container.read(appStateProvider);
  var stopping = false;
  var visible = true;

  // `_register_jobs`: core's runner with the window's jobs; the first
  // auto-run is anchored to the last successful refresh.
  final loop = registerJobs(
    state,
    // Phone without background running: runs wait while the app is in
    // the background (the OS freezes it there, mid-run).
    paused: _isPhone ? () => !visible && !_phoneBackgroundOn(state) : null,
    stopped: () => stopping,
    keepAwake: Platform.isAndroid ? androidKeepAwake : null,
    intervalProvider: () =>
        checkIntervalMinutes(state.get('check_interval_minutes', 60)),
  );
  // Non-blocking release check (silent when offline).
  try {
    state.startUpdateCheck();
  } catch (_) {}

  if (Platform.isAndroid) {
    const channel = AndroidChannel();
    channel.setLaunchRouteHandler(state.applyLaunchRoute);
    final launchRoute = await channel.takeLaunchRoute();
    if (launchRoute != null && launchRoute.isNotEmpty) {
      state.applyLaunchRoute(launchRoute);
    }
    final phone = PhoneBackground(state, loop, channel);
    state.onPrimaryChanged = () => phone.notifier.poke();
    container.listen(appStateProvider, (_, _) => phone.notifier.poke());
    startPhoneBackground(state, phone);
    AppLifecycleListener(onStateChange: (s) {
      visible = s == AppLifecycleState.resumed;
      // The engine drops this isolate: no hand-off to its port any more.
      if (s == AppLifecycleState.detached) unregisterUiRefreshPort();
      if (s == AppLifecycleState.resumed) {
        // Back from the system's settings or after a while away.
        state.syncAndroidState();
        unawaited(phone.sync());
        state.onChanged();
      }
    });
    loop.start();
    try {
      // A wake while this isolate lives: its runner does the due job on
      // its next 5 s tick (Python: the alarm only wakes the CPU for the
      // running scheduler). Keep the CPU up for that tick; the job then
      // holds its own lock. Not due: arm the wake for the due time.
      await registerUiRefreshPort(ReceivePort(), onHandOff: () async {
        final now = clock.now();
        if (now.isBefore(nextDue(loop.lastRun, loop.intervalMinutes, now))) {
          await phone.scheduleWake();
        }
        await androidKeepAwake(
            () => Future<void>.delayed(const Duration(seconds: 15)),
            minutes: 1);
      });
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: background hand-off port failed ($e).');
    }
    return;
  }
  loop.start();
  if (_isPhone) return;

  final tray = DesktopTrayController(
    iconPath: Platform.isWindows
        ? 'assets/tray-icon.ico'
        : 'assets/tray-icon.png',
    strings: trayStrings(state),
    onRefreshNow: () async => state.trayRefreshAll(),
    isPaused: () => automationPaused(state.config.data),
    onTogglePause: () async =>
        state.save({'automation_paused': !automationPaused(state.config.data)}),
    hideToTraySetting: () => state.get('minimize_to_tray', true) != false,
    onQuit: () async {
      stopping = true;
      loop.stop();
      await ctx.guard?.close();
    },
  );
  await tray.initialize(minimized: ctx.minimized);
  // The tray re-reads the labels when the language or active account changes.
  void refreshTrayMenu() =>
      unawaited(tray.updateMenu(strings: trayStrings(state)));
  state.configListeners.add(refreshTrayMenu);
  state.onAccountChanged = refreshTrayMenu;
  // A second launch restores this window.
  ctx.guard?.setOnShow(() => unawaited(tray.showWindow()));
  ctx.guard?.onQuit = () => unawaited(tray.quit());
  installDesktopNotifier();
}

/// The tray menu in the configured language (Python's tray applied
/// `config.language` itself, `_apply_language`; here `AppState` did).
/// When >1 account exists, appends the active account's label to Pause (§7.2 step 8).
TrayStrings trayStrings([AppState? state]) {
  final basePause = Strings.get('tray_pause');
  final pauseLabel = (state != null && state.isMultiAccount)
      ? '$basePause (${state.activeAccountDisplayLabel})'
      : basePause;
  return TrayStrings(
    open: Strings.get('tray_open'),
    refreshNow: Strings.get('tray_refresh'),
    pause: pauseLabel,
    resume: pauseLabel,
    quit: Strings.get('tray_quit'),
  );
}

/// Background running is possible here (Android) and switched on.
bool _phoneBackgroundOn(AppState state) {
  try {
    return Platform.isAndroid &&
        backgroundSwitchOn(state.get('run_in_background', true));
  } catch (_) {
    return false;
  }
}

/// Android background service + wake-up alarm, following the setting.
/// (Public for the tests of `_setup_phone_background`.)
/// Port of `_setup_phone_background` / `_schedule_phone_wake`.
class PhoneBackground {
  /// [onAndroid] and [startNotifier] are test seams (Python's tests patch
  /// `android.available` and `StatusNotifier.start`).
  PhoneBackground(this.state, this.loop, this.channel,
      {this.onAndroid, this.startNotifier = true}) {
    notifier = StatusNotifier(
      () => _isOn() ? state.backgroundStatusInputs() : null,
      (c) {
        unawaited(channel.updateBackgroundNotification(
            title: c.title, text: c.text, sub: c.sub, rows: c.rowsJson()));
        return true;
      },
      _fallback,
    );
  }

  final AppState state;
  final PeriodicRunner loop;
  final AndroidChannel channel;
  final bool Function()? onAndroid;
  final bool startNotifier;

  /// `_phone_background_on`: Android and the switch on.
  bool _isOn() => (onAndroid ?? () => Platform.isAndroid)() &&
      backgroundSwitchOn(state.get('run_in_background', true));
  late final StatusNotifier notifier;
  bool _asked = false;
  bool? _on;
  int? _interval;
  bool? _allowed;

  int _intervalMinutes() {
    // `max(1, int(float(get(...) or 60)))`.
    final n =
        checkIntervalMinutes(state.get('check_interval_minutes', 60)).toInt();
    return n < 1 ? 1 : n;
  }

  (String, String) _fallback() => (
        Strings.get('bg_notif_title'),
        Strings.format('bg_notif_text', {'n': _intervalMinutes()}),
      );

  void start() {
    // `_setup_phone_background` chains the runner's result hook.
    final previous = loop.onResult;
    loop.onResult = (result) {
      previous?.call(result);
      afterRun();
    };
    state.configListeners.add(() => unawaited(sync()));
    unawaited(sync());
    // Widget and wake-up alarms need no running Dart, but the first data
    // comes from here (later ones from each config save and cache reload).
    state.syncAndroidState();
  }

  void afterRun() {
    unawaited(sync()); // e.g. the wizard just finished: ask now
    if (_isOn()) unawaited(scheduleWake());
    // Also after a skipped or failed run: a new day redraws the widget.
    state.syncAndroidState();
  }

  Future<void> scheduleWake() async {
    try {
      final due = nextDue(loop.lastRun, loop.intervalMinutes, clock.now());
      // A little after due: the loop's tick (5 s) must see it as due.
      if (await channel.scheduleWake(due.add(const Duration(seconds: 10)))) {
        // ignore: avoid_print
        print('Info: next background check at '
            '${due.hour.toString().padLeft(2, '0')}:'
            '${due.minute.toString().padLeft(2, '0')}.');
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: could not schedule the next wake-up ($e)');
    }
  }

  Future<void> sync() async {
    try {
      final on = _isOn();
      if (on &&
          !_asked &&
          !state.notificationPermissionAsked &&
          !state.setupPending &&
          state.tutorial == null) {
        // Android 13+: allow notifications? Not over the setup wizard or the
        // first tutorial; closing them saves config and brings us back here.
        _asked = true;
        state.notificationPermissionAsked = true;
        await channel.requestNotificationPermission();
      }
      final allowed = on ? await channel.notificationsEnabled() : false;
      final interval = _intervalMinutes();
      notifier.poke(); // the overview's items, the language, …
      if (_on == on &&
          _interval == interval &&
          (!on || _allowed == allowed)) {
        return;
      }
      _on = on;
      _interval = interval;
      _allowed = allowed;
      if (!on) {
        await channel.stopBackground();
        // ignore: avoid_print
        print('Info: background running off.');
        return;
      }
      // ignore: avoid_print
      print('Info: background running on (every $interval min).');
      StatusContent? content;
      try {
        content = notifier.current();
      } on Object catch (e) {
        // ignore: avoid_print
        print('Warning: background notification overview failed ($e)');
      }
      final (title, text) = _fallback();
      await channel.startBackground({
        'title': content?.title ?? title,
        'text': content?.text ?? text,
        'sub': content?.sub ?? '',
        'rows': content?.rowsJson() ?? '',
        'channel': Strings.get('bg_channel'),
        'boot_title': Strings.get('bg_boot_title'),
        'boot_text': Strings.get('bg_boot_text'),
        'events_channel': Strings.get('events_channel'),
      });
      if (startNotifier) notifier.start();
      await scheduleWake();
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: background running setup failed ($e)');
    }
  }
}
