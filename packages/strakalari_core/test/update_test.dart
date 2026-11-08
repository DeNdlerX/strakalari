// Port of tests/test_update.py (pure cases).
//
// Deferred to their owners: TestStrings (Flet UI strings, phase 5/6),
// test_switch_channel_updates_banner (app state, phase 4/5),
// test_settings_diagnostics_builds_with_channel (settings view, phase 6),
// the ConfigManager channel cases (config territory; the default-channel
// mirror is covered by config_test.dart) and TestConfigChannel validation
// (covered by config validation tests).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/platform/notifier.dart' as notifier;
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/update.dart';

Map<String, Object?> rel(
  String tag, {
  bool prerelease = false,
  bool draft = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/DeNdlerX/strakalari/releases/tag/$tag',
  'name': tag,
  'prerelease': prerelease,
  'draft': draft,
  'published_at': '2026-01-01T00:00:00Z',
};

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('update_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    setLanguage('cs');
    currentAppVersion = '0.0.0';
    fetchReleasesHook = null;
    notifier.notifierBackend = null;
  });

  tearDown(() {
    setEnvironmentOverride(null);
    setLanguage('cs');
    currentAppVersion = '0.0.0';
    fetchReleasesHook = null;
    notifier.notifierBackend = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('parseVersion', () {
    test('simple', () => expect(parseVersion('1.2.3'), [1, 2, 3]));
    test('stripsVPrefix', () => expect(parseVersion('v1.2.3'), [1, 2, 3]));
    test('ignoresSuffix', () => expect(parseVersion('1.2.3-beta'), [1, 2, 3]));
    test('emptyIsZero', () => expect(parseVersion(''), [0]));
  });

  group('isNewer', () {
    test('newerPatch', () => expect(isNewer('1.0.1', '1.0.0'), isTrue));
    test('sameIsNotNewer', () => expect(isNewer('1.0.0', '1.0.0'), isFalse));
    test('olderIsNotNewer', () => expect(isNewer('0.9.9', '1.0.0'), isFalse));
    test('tagPrefixIgnored', () => expect(isNewer('v2.0.0', '1.9.9'), isTrue));
    test('newerMajor', () => expect(isNewer('2.0.0', '1.99.99'), isTrue));
    test('stableIsNewerThanItsBeta', () {
      expect(isNewer('0.1.0', '0.1.0-beta.1'), isTrue);
      expect(isNewer('0.1.0-beta.1', '0.1.0'), isFalse);
    });
    test('betaIsNewerThanPreviousStable', () {
      expect(isNewer('0.2.0-beta.1', '0.1.0'), isTrue);
    });
    test('betaNumbersCompareNumerically', () {
      expect(isNewer('0.1.0-beta.10', '0.1.0-beta.9'), isTrue);
      expect(isNewer('0.1.0-beta10', '0.1.0-beta9'), isTrue);
    });
    test('rcAfterBeta', () {
      expect(isNewer('0.1.0-rc.1', '0.1.0-beta.3'), isTrue);
    });
    test('trailingZerosEqual', () {
      expect(isNewer('0.1.0', '0.1'), isFalse);
      expect(isNewer('0.1', '0.1.0'), isFalse);
    });
    test('oldDevBuildSeesFirstBeta', () {
      expect(isNewer('0.1.0-beta.1', '0.0.1'), isTrue);
    });
  });

  group('isPrereleaseVersion', () {
    test('detectsSuffix', () {
      expect(isPrereleaseVersion('v0.1.0-beta.1'), isTrue);
      expect(isPrereleaseVersion('1.0.0rc1'), isTrue);
    });
    test('plainIsStable', () {
      expect(isPrereleaseVersion('v1.2.3'), isFalse);
      expect(isPrereleaseVersion('1.2.3+build5'), isFalse);
    });
  });

  group('normalizeChannel', () {
    test('values', () {
      expect(normalizeChannel('beta'), 'beta');
      expect(normalizeChannel('BETA '), 'beta');
      expect(normalizeChannel('stable'), 'stable');
      expect(normalizeChannel(null), 'stable');
      expect(normalizeChannel('nightly'), 'stable');
    });
  });

  group('pickRelease', () {
    final releases = [
      rel('v0.3.0', draft: true),
      rel('v0.2.0-beta.1', prerelease: true),
      rel('v0.1.0'),
      rel('v0.1.0-beta.2', prerelease: true),
    ];

    test('stableSkipsPrereleasesAndDrafts', () {
      expect(pickRelease(releases, 'stable')!['version'], '0.1.0');
    });

    test('betaTakesNewestOfBoth', () {
      final info = pickRelease(releases, 'beta')!;
      expect(info['version'], '0.2.0-beta.1');
      expect(info['prerelease'], isTrue);
    });

    test('betaIncludesStableWhenItIsNewest', () {
      final both = [rel('v0.1.0-beta.1', prerelease: true), rel('v0.1.0')];
      expect(pickRelease(both, 'beta')!['version'], '0.1.0');
    });

    test('suffixCountsAsPrereleaseEvenWithoutFlag', () {
      final only = [rel('v0.1.0-beta.1')];
      expect(pickRelease(only, 'stable'), isNull);
      expect(pickRelease(only, 'beta')!['version'], '0.1.0-beta.1');
    });

    test('onlyBetasStableGetsNone', () {
      expect(
        pickRelease([rel('v0.1.0-beta.1', prerelease: true)], 'stable'),
        isNull,
      );
    });

    test('empty', () => expect(pickRelease([], 'beta'), isNull));
  });

  group('fetchLatestRelease', () {
    test('success', () async {
      final payload = [rel('v1.2.3'), rel('v1.3.0-beta.1', prerelease: true)];
      fetchReleasesHook = (_) async => jsonEncode(payload);
      final info = (await fetchLatestRelease())!;
      expect(info['version'], '1.2.3');
      expect((info['url'] as String).endsWith('v1.2.3'), isTrue);
      final beta = await fetchLatestRelease('beta');
      expect(beta!['version'], '1.3.0-beta.1');
    });

    test('usesListEndpoint', () async {
      String? seenUrl;
      fetchReleasesHook = (url) async {
        seenUrl = '$url';
        return '[]';
      };
      expect(await fetchLatestRelease('beta'), isNull);
      // /releases/latest never returns pre-releases.
      expect(seenUrl, isNot(contains('/releases/latest')));
      expect(seenUrl, contains('/releases'));
    });

    test('networkFailureReturnsNone', () async {
      fetchReleasesHook = (_) async => throw const OSError('offline');
      expect(await fetchLatestRelease(), isNull);
    });

    test('nonListPayloadReturnsNone', () async {
      fetchReleasesHook = (_) async => '{"message": "Not Found"}';
      expect(await fetchLatestRelease(), isNull);
    });
  });

  group('checkForUpdates', () {
    test('oneFetchServesBothChannels', () async {
      var calls = 0;
      final payload = [rel('v0.1.0-beta.1', prerelease: true), rel('v0.0.9')];
      fetchReleasesHook = (_) async {
        calls++;
        return jsonEncode(payload);
      };
      expect((await checkForUpdates(channel: 'stable'))!['version'], '0.0.9');
      // Fresh cache: switching channel needs no new request.
      expect(
        (await checkForUpdates(channel: 'beta'))!['version'],
        '0.1.0-beta.1',
      );
      expect(calls, 1);
      expect(loadCached('beta')!['version'], '0.1.0-beta.1');
      expect(loadCached('stable')!['version'], '0.0.9');
    });

    test('failureKeepsStaleCache', () async {
      saveCached({
        'stable': {'version': '1.0.0'},
        'beta': null,
      }, checkedAt: 0);
      fetchReleasesHook = (_) async => throw const OSError('offline');
      expect((await checkForUpdates(channel: 'stable'))!['version'], '1.0.0');
      expect(await checkForUpdates(channel: 'beta'), isNull);
    });

    test('legacyCacheFormatIsIgnored', () async {
      final path = cachePath();
      File(
        path,
      ).writeAsStringSync(jsonEncode({'version': '9.9.9', 'checked_at': 9e12}));
      expect(loadCached('stable'), isNull);
    });
  });

  group('shouldCheck', () {
    test('noCache', () => expect(shouldCheck(null), isTrue));

    test('fresh', () {
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      expect(shouldCheck({'checked_at': now}), isFalse);
    });

    test('stale', () {
      final old =
          DateTime.now().millisecondsSinceEpoch / 1000.0 - checkIntervalS - 1;
      expect(shouldCheck({'checked_at': old}), isTrue);
    });
  });

  group('updateAvailable', () {
    test('detectsNewer', () {
      currentAppVersion = '1.0.0';
      expect(updateAvailable({'version': '1.0.1'}), isTrue);
    });

    test('sameVersionNotAvailable', () {
      currentAppVersion = '1.0.0';
      expect(updateAvailable({'version': '1.0.0'}), isFalse);
    });

    test('noneInfo', () {
      currentAppVersion = '1.0.0';
      expect(updateAvailable(null), isFalse);
    });
  });

  group('updateNotice', () {
    test('eachReleaseIsAnnouncedOnce', () {
      final sent = <String>[];
      notifier.notifierBackend = _RecordingBackend(sent);
      currentAppVersion = '1.0.0';
      saveCached({
        'stable': {'version': '1.0.1'},
        'beta': null,
      });
      expect(notifyNewRelease({'version': '1.0.1'}, {}), isTrue);
      // A later daily check keeps the record: no second notification.
      saveCached({
        'stable': {'version': '1.0.1'},
        'beta': null,
      });
      expect(notifyNewRelease({'version': '1.0.1'}, {}), isFalse);
      expect(notifyNewRelease({'version': '1.0.2'}, {}), isTrue);
      expect(sent, ['update_available', 'update_available']);
    });

    test('nothingNewerOrSwitchedOffSendsNothing', () {
      final sent = <String>[];
      notifier.notifierBackend = _RecordingBackend(sent);
      currentAppVersion = '1.0.0';
      expect(notifyNewRelease({'version': '1.0.0'}, {}), isFalse);
      expect(notifyNewRelease(null, {}), isFalse);
      expect(
        notifyNewRelease({'version': '2.0.0'}, {'update_available': false}),
        isFalse,
      );
      expect(sent, isEmpty);
    });
  });

  group('defaultChannel', () {
    test('followsBuild', () {
      currentAppVersion = '0.2.0-beta.1';
      expect(defaultChannel(), 'beta');
      currentAppVersion = '0.2.0';
      expect(defaultChannel(), 'stable');
    });
  });
}

class _RecordingBackend implements notifier.NotifierBackend {
  final List<String> sent;
  _RecordingBackend(this.sent);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    sent.add(tag);
    return true;
  }
}
