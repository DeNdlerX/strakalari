import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}

Future<void> _loadRealFonts() async {
  // The Flutter SDK that runs this tool: FLUTTER_ROOT, else ~/flutter/3.44.8.
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  final root = Platform.environment['FLUTTER_ROOT'] ?? '$home/flutter/3.44.8';
  final fontDir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!fontDir.existsSync()) return;

  final robotoLoader = FontLoader('Roboto');
  for (final name in [
    'roboto-regular.ttf',
    'roboto-bold.ttf',
    'roboto-medium.ttf',
  ]) {
    final file = File('${fontDir.path}/$name');
    if (file.existsSync()) {
      robotoLoader.addFont(file.readAsBytes().then(ByteData.sublistView));
    }
  }
  await robotoLoader.load();

  final iconsLoader = FontLoader('MaterialIcons');
  final iconFile = File('${fontDir.path}/materialicons-regular.otf');
  if (iconFile.existsSync()) {
    iconsLoader.addFont(iconFile.readAsBytes().then(ByteData.sublistView));
    await iconsLoader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final outDir = Directory('../build/parity-screens/flutter');
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  const screens = [
    'today',
    'timetable',
    'absences',
    'marks',
    'planner',
    'lunches',
    'activity',
    'settings',
    'more',
    'wizard',
  ];

  const languages = ['cs', 'en'];
  const themes = ['dark', 'light'];
  const viewports = [
    (1280, 800),
    (390, 844),
  ];

  setUpAll(() async {
    await _loadRealFonts();
  });

  for (final lang in languages) {
    for (final theme in themes) {
      for (final (width, height) in viewports) {
        for (final screen in screens) {
          testWidgets(
              'capture $screen-$lang-$theme-$width',
              (tester) async {
            tester.view.physicalSize = Size(width.toDouble(), height.toDouble());
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });

            // One demo folder per language AND theme, written before the
            // AppState exists so its constructor reads the theme and the
            // language like the real start-up does.
            // The wizard is captured on a fresh folder without credentials.
            final isWizard = screen == 'wizard';
            final demoDir = Directory(
                    '../build/parity-screens/${isWizard ? 'fresh' : 'demo'}-$lang-$theme')
                .absolute;
            await tester.runAsync(() async {
              if (isWizard) {
                demoDir.createSync(recursive: true);
                File('${demoDir.path}/config.json').writeAsStringSync(
                    '{"theme": "$theme", "language": "$lang"}');
              } else if (!demoDir.existsSync() || screen == 'today') {
                final python =
                    Platform.environment['STRAKALARI_PYTHON'] ?? 'python';
                final r = await Process.run(python, [
                  '../tools/demo_data.py',
                  'generate',
                  demoDir.path,
                  '--lang',
                  lang,
                  '--theme',
                  theme,
                ], environment: {'PYTHONUTF8': '1'});
                if (r.exitCode != 0) {
                  throw StateError('demo_data.py failed: ${r.stderr}');
                }
              }
            });
            setEnvironmentOverride({
              ...Platform.environment,
              'STRAKALARI_DATA_DIR': demoDir.path,
              'STRAKALARI_NO_KEYRING': '1',
            });
            allowMissingKeyStoreForTesting = true;
            clearKeyCache();

            final state = AppState();
            state.wizardDismissed = screen != 'wizard';

            final repaintKey = GlobalKey();
            final router = buildRouter();

            final container = ProviderContainer(
              overrides: [
                appStateProvider.overrideWith(() => FixedAppStateController(state)),
              ],
            );

            // Exactly what `MyApp` (lib/main.dart) builds.
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: RepaintBoundary(
                  key: repaintKey,
                  child: Consumer(builder: (context, ref, _) {
                    final appState = ref.watch(appStateProvider);
                    final light = appState.tok.mode == 'light';
                    return MaterialApp.router(
                      debugShowCheckedModeBanner: false,
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
                      routerConfig: router,
                    );
                  }),
                ),
              ),
            );

            router.go('/$screen');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 150));

            await tester.runAsync(() async {
              final boundary = repaintKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1.0);
              final byteData =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              final bytes = byteData!.buffer.asUint8List();

              final dest = File('${outDir.path}/$screen-$lang-$theme-$width.png');
              dest.writeAsBytesSync(bytes);
            });
          });
        }
      }
    }
  }
}
