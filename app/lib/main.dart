// UI entry (+ the headless Android entry point stub).
//
// Port of strakalari/flet_ui/__main__.py + the `run()` bootstrap in
// strakalari/flet_ui/app.py: demo data dir via `STRAKALARI_DATA_DIR`
// (phase 7 resolves it exactly like `core.helpers.get_user_data_dir`),
// Riverpod scope, MaterialApp with both token themes, cs/en
// localizations, and the go_router shell.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controllers/app_state.dart';
import 'l10n/strings.dart';
import 'platform/android/background.dart' as android_bg;
import 'platform/notifications.dart';
import 'shell/router.dart';
import 'widgets/error_boundary.dart';

/// Headless Android entry point (PLAN 3.4): `WakeReceiver`/`RefreshReceiver`
/// starts a headless FlutterEngine running this instead of the UI.
/// One-line trampoline into the real entry in `platform/android/background.dart`
/// (the engine resolves the fallback name in the root library).
/// Must stay tear-offable: hence the explicit `vm:entry-point` pragma.
@pragma('vm:entry-point')
Future<void> backgroundMain() => android_bg.androidBackgroundEntry();

final _router = buildRouter();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ensureNotifierBackend();
  installErrorWidgetBuilder();
  runApp(const ProviderScope(child: MyApp()));
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
      theme: appState.tok.toThemeData(),
      darkTheme: appState.tok.toThemeData(),
      themeMode: light ? ThemeMode.light : ThemeMode.dark,
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

