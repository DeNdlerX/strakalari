// Source guards for the Android wiring that no Dart test can run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mainActivityGivesTheChannelItsScreenForThePermissionPrompt', () {
    // C-M2: the channel is attached by hand, so ActivityAware never runs;
    // without the activity `requestNotificationPermission` does nothing.
    final file = File(
        'android/app/src/main/kotlin/io/github/dendlerx/strakalari/MainActivity.kt');
    if (!file.existsSync()) return; // run from elsewhere
    final text = file.readAsStringSync();
    expect(text, contains('setActivity(this)'));
    expect(text, contains('setActivity(null)'));
  });

  test('aProdReleaseWithoutTheRealKeyIsRefused', () {
    // C-M5: the debug-key fallback is for the phonetest flavor only.
    final file = File('android/app/build.gradle.kts');
    if (!file.existsSync()) return;
    final text = file.readAsStringSync();
    expect(text, contains('it.name == "preProdReleaseBuild"'));
    expect(text, contains('if (!releaseSigningFound)'));
    expect(text, contains('throw GradleException('));
  });
}
