// UI entry (+ the headless Android entry point stub).
//
// Port of strakalari/flet_ui/__main__.py + the `run()` bootstrap in
// strakalari/flet_ui/app.py: demo data dir via `STRAKALARI_DATA_DIR`
// (phase 7 resolves it exactly like `core.helpers.get_user_data_dir`),
// Riverpod scope, MaterialApp with both token themes, cs/en
// localizations, and the go_router shell.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' show getUserDataDir, notifierBackend;

import 'controllers/app_state.dart';
import 'l10n/strings.dart';
import 'platform/android/background.dart' as android_bg;
import 'platform/desktop/console_log.dart';
import 'platform/desktop/store_package.dart';
import 'platform/notifications.dart';
import 'platform/startup.dart';
import 'shell/router.dart';
import 'shell/theme.dart';
import 'widgets/error_boundary.dart';

/// Headless Android entry point (PLAN 3.4): `WakeReceiver`/`RefreshReceiver`
/// starts a headless FlutterEngine running this instead of the UI.
/// One-line trampoline into the real entry in `platform/android/background.dart`
/// (the engine resolves the fallback name in the root library).
/// Must stay tear-offable: hence the explicit `vm:entry-point` pragma.
@pragma('vm:entry-point')
Future<void> backgroundMain() => android_bg.androidBackgroundEntry();

final _router = buildRouter();

Future<void> main(List<String> args) async {
  // Store (MSIX) build? Decides the data folder, so it comes first.
  if (Platform.isWindows) registerStorePackageProbe();
  // `ensure_stdio`: the Windows release build has no console, so prints
  // and uncaught errors go to console.log in the data folder.
  if (windowedBuild) {
    final log = openConsoleLog(getUserDataDir());
    if (log != null) return runWithConsoleLog(log, () => _main(args));
  }
  return _main(args);
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Data dir, key store, single instance, F4 layout move (may exit this process).
  final ctx = await prepareStartup(args);
  if (notifierBackend == null) ensureNotifierBackend(); // tests, iOS
  installErrorWidgetBuilder();
  if (ctx.layoutResult?.isRegistryFailed == true) {
    // Registry unreadable AND rebuild failed: never fall back to root files
    // and never start refreshes/sends/orders (§2.1).
    runApp(_RegistryFailedApp(reason: ctx.layoutResult!.error ?? ''));
    return;
  }
  final container = ProviderContainer(
    overrides: [
      startupLayoutProvider
          .overrideWithValue((layout: ctx.layoutResult, rootDir: ctx.rootDir)),
    ],
  );
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  // Scheduler, tray, phone background (Python: `main(page)` after render).
  await startPlatformServices(container, ctx);
}

class _RegistryFailedApp extends StatelessWidget {
  final String reason;
  const _RegistryFailedApp({required this.reason});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Strings.get('app_title'),
      theme: darkTokens.toThemeData(),
      home: Scaffold(
        backgroundColor: darkTokens.bg,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: darkTokens.red),
                  const SizedBox(height: 16),
                  Text(
                    Strings.get('app_title'),
                    style: TextStyle(
                      color: darkTokens.text,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    reason.isNotEmpty
                        ? reason
                        : 'Account registry could not be loaded or rebuilt.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: darkTokens.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Root widget. Kept under the template name so the phase-0 smoke test
/// still compiles; phase 6 replaces it with real widget tests.
class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final light = appState.tok.mode == 'light';
    return MaterialApp.router(
      title: Strings.get('app_title'),
      theme: lightTokens.toThemeData(),
      darkTheme: darkTokens.toThemeData(),
      themeMode: light ? ThemeMode.light : ThemeMode.dark,
      // Keep Theme.of(context) locked in the same frame as appState.tok so
      // shell bars and body never split across light and dark during rebuilds.
      themeAnimationStyle: AnimationStyle.noAnimation,
      locale: Locale(Strings.lang),
      supportedLocales: const [Locale('cs'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: _router,
    );
  }
}

