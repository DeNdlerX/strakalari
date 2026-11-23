// Port of tests/test_icons.py (branding assets), plus the Flutter-side
// places the icons are used (C-M4): the Windows exe icon, the tray glyph
// and the Android launcher icon are the repo's own files.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

final _assets = Directory('../assets').path;

Uint8List _bytes(String name) => File('$_assets/$name').readAsBytesSync();

/// Width and height from a PNG's IHDR chunk.
(int, int) _pngSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  expect(b.sublist(1, 4), 'PNG'.codeUnits);
  return (d.getUint32(16), d.getUint32(20));
}

/// The sizes listed in an .ico directory (0 means 256).
Set<(int, int)> _icoSizes(Uint8List b) {
  final d = ByteData.sublistView(b);
  final count = d.getUint16(4, Endian.little);
  return {
    for (var i = 0; i < count; i++)
      (b[6 + 16 * i] == 0 ? 256 : b[6 + 16 * i], b[7 + 16 * i] == 0 ? 256 : b[7 + 16 * i]),
  };
}

/// Largest PNG-encoded element of an .icns file.
int _icnsMaxSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  expect(String.fromCharCodes(b.sublist(0, 4)), 'icns');
  var best = 0;
  var at = 8;
  while (at + 8 <= b.length) {
    final len = d.getUint32(at + 4);
    if (len < 8) break;
    final data = b.sublist(at + 8, at + len);
    if (data.length > 24 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47) {
      final (w, _) = _pngSize(data);
      if (w > best) best = w;
    }
    at += len;
  }
  return best;
}

Future<(bool, int)> _alpha(WidgetTester tester, String name) async {
  return (await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(_bytes(name));
    final image = (await codec.getNextFrame()).image;
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var min = 255;
    for (var i = 3; i < rgba.lengthInBytes; i += 4) {
      final a = rgba.getUint8(i);
      if (a < min) min = a;
    }
    // PNG colour type 4 (grey + alpha) or 6 (RGBA) carries an alpha band.
    final type = _bytes(name)[25];
    return (type == 4 || type == 6, min);
  }))!;
}

void main() {
  group('TestAssetSources', () {
    test('svgMastersExist', () {
      expect(File('$_assets/logo.svg').existsSync(), isTrue);
      expect(File('$_assets/tray-icon.svg').existsSync(), isTrue);
    });

    test('logoSvgNamespacesAndLayers', () {
      final text = File('$_assets/logo.svg').readAsStringSync();
      expect(text, contains('xmlns="http://www.w3.org/2000/svg"'));
      for (final layer in ['id="background"', 'id="magpie"']) {
        expect(text, contains(layer));
      }
    });

    test('traySvgIsFlat', () {
      final text = File('$_assets/tray-icon.svg').readAsStringSync();
      expect(text, isNot(contains('feDropShadow')));
      expect(text, isNot(contains('linearGradient')));
      expect(text, isNot(contains('ink-effect')));
    });
  });

  group('TestDistributionSizes', () {
    test('hicolorLogoSet', () {
      for (final size in [16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512]) {
        expect(_pngSize(_bytes('logo-$size.png')), (size, size), reason: 'logo-$size.png');
      }
    });

    test('trayPngSet', () {
      for (final (name, size) in [
        ('tray-icon.png', 64), ('tray-icon-16.png', 16), ('tray-icon-22.png', 22),
        ('tray-icon-24.png', 24), ('tray-icon-32.png', 32), ('tray-icon-48.png', 48),
      ]) {
        expect(_pngSize(_bytes(name)), (size, size), reason: name);
      }
    });

    testWidgets('rastersHaveTransparency', (tester) async {
      for (final name in ['logo-256.png', 'tray-icon.png', 'icon.png', 'favicon.png']) {
        final (hasAlpha, min) = await _alpha(tester, name);
        expect(hasAlpha, isTrue, reason: name);
        expect(min, 0, reason: name);
      }
    });

    test('windowsIcoMultisize', () {
      expect(_icoSizes(_bytes('icon.ico')), containsAll([(16, 16), (32, 32), (48, 48), (256, 256)]));
      expect(_icoSizes(_bytes('tray-icon.ico')), containsAll([(16, 16), (32, 32)]));
    });

    test('macosIcnsExists', () {
      expect(_icnsMaxSize(_bytes('icon.icns')), greaterThanOrEqualTo(512));
    });

    test('webIcons', () {
      expect(_pngSize(_bytes('favicon.png')), (32, 32));
      expect(_pngSize(_bytes('android-chrome-192.png')), (192, 192));
      expect(_pngSize(_bytes('android-chrome-512.png')), (512, 512));
    });
  });

  group('TestAssetHelpers (Flutter build)', () {
    test('windowIconIsTheRepoIcon', () {
      // `window_icon_path` → the exe's own icon resource in Flutter.
      expect(File('windows/runner/resources/app_icon.ico').readAsBytesSync(), _bytes('icon.ico'));
    });

    test('trayIconIsBundledVariant', () {
      // `tray_icon_path`: the app bundles the repo's tray glyphs unchanged.
      for (final name in ['tray-icon.ico', 'tray-icon.png']) {
        expect(File('assets/$name').readAsBytesSync(), _bytes(name), reason: name);
      }
    });

    test('trayLoaderUsesBundledGlyph', () {
      // `_icon_image()` is the 64 px glyph.
      expect(_pngSize(File('assets/tray-icon.png').readAsBytesSync()), (64, 64));
    });

    test('androidLauncherIconIsTheAppIcon', () {
      for (final (dpi, size) in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]) {
        final f = File('android/app/src/main/res/mipmap-$dpi/ic_launcher.png');
        expect(_pngSize(f.readAsBytesSync()), (size, size), reason: dpi);
        expect(File('android/app/src/main/res/drawable-$dpi/ic_launcher_foreground.png').existsSync(),
            isTrue, reason: dpi);
      }
      final adaptive = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      expect(adaptive, contains('@drawable/ic_launcher_foreground'));
      expect(adaptive, contains('@color/ic_launcher_background'));
    });

    test('androidManifestKeepsTheOldIdentity', () {
      final text = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(text, contains('android:label="Strakaláři"'));
      expect(text, contains('android:allowBackup="false"'));
      expect(text, contains('android:enableOnBackInvokedCallback="true"'));
    });
  });
}
