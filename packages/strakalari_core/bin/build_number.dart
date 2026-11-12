// Prints the Android versionCode for a release version, for
// `flutter build apk|appbundle --build-number=…` (tools/make_mobile.py did
// this for the Flet build).
//
//   dart run strakalari_core:build_number 0.2.0-beta.1   → 20031
import 'dart:io';

import 'package:strakalari_core/strakalari_core.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: build_number <version>');
    exit(2);
  }
  try {
    stdout.writeln(buildNumber(args.single));
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
