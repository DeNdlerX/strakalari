import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/lunches/lunches_live.dart';
import 'package:app/features/marks/marks_live.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/features/timetable/timetable_live.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/l10n/strings.dart';

void main() {
  const screens = ['today', 'timetable', 'marks', 'lunches', 'planner'];

  for (final lang in ['cs', 'en']) {
    for (final stem in screens) {
      testWidgets('Capture Flutter demo screenshot ($stem-$lang)',
          (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final demoDir = Directory('../build/parity-screens/demo-$lang').absolute;
        setEnvironmentOverride({
          'STRAKALARI_DATA_DIR': demoDir.path,
          'STRAKALARI_NO_KEYRING': '1',
        });
        allowMissingKeyStoreForTesting = true;
        clearKeyCache();
        Strings.lang = lang;

        final outDir = Directory('../build/parity-screens/flutter');
        if (!outDir.existsSync()) {
          outDir.createSync(recursive: true);
        }

        final tokens = AppTokens.dark();
        final Widget screenWidget;
        switch (stem) {
          case 'today':
            screenWidget = LiveTodayView(tokens: tokens);
            break;
          case 'timetable':
            screenWidget = LiveTimetableView(tokens: tokens);
            break;
          case 'marks':
            screenWidget = LiveMarksView(tokens: tokens);
            break;
          case 'lunches':
            screenWidget = const LiveLunchesView(narrow: false);
            break;
          case 'planner':
            screenWidget = const LivePlannerView(narrow: false);
            break;
          default:
            throw ArgumentError('Unknown stem: $stem');
        }

        final repaintKey = GlobalKey();

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                body: RepaintBoundary(
                  key: repaintKey,
                  child: screenWidget,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.runAsync(() async {
          final boundary = repaintKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.0);
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          final bytes = byteData!.buffer.asUint8List();

          final dest = File('${outDir.path}/$stem-$lang.png');
          dest.writeAsBytesSync(bytes);
          // ignore: avoid_print
          print('Captured ${dest.path} (${bytes.length ~/ 1024} KB)');
        });
      });
    }
  }
}
