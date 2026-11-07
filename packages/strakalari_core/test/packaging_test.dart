import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/packaging.dart';

void main() {
  tearDown(() {
    setEnvironmentOverride(null);
    androidDistributionChannel = null;
    setStorePackageProbe(null);
  });

  group('mobilePlatform', () {
    test('desktopIsNotMobile', () {
      setEnvironmentOverride({});
      expect(mobilePlatform(), isNull);
      expect(isMobile(), isFalse);
    });

    test('fletPlatformEnv', () {
      for (final value in ['android', 'ios', 'IOS ']) {
        setEnvironmentOverride({'FLET_PLATFORM': value});
        expect(mobilePlatform(), value.trim().toLowerCase());
        expect(isMobile(), isTrue);
      }
    });

    test('desktopFletBuildIsNotMobile', () {
      setEnvironmentOverride({'FLET_PLATFORM': 'windows'});
      expect(isMobile(), isFalse);
    });
  });

  group('mobileStore', () {
    test('iosComesFromAppStore', () {
      setEnvironmentOverride({'FLET_PLATFORM': 'ios'});
      expect(mobileStore(), 'app_store');
    });

    test('androidWithoutDistributionIsNull', () {
      setEnvironmentOverride({'FLET_PLATFORM': 'android'});
      expect(mobileStore(), isNull);
    });

    test('androidPlayChannel', () {
      setEnvironmentOverride({'FLET_PLATFORM': 'android'});
      androidDistributionChannel = 'play';
      expect(mobileStore(), 'play');
    });

    test('offPhoneIsNull', () {
      setEnvironmentOverride({});
      expect(mobileStore(), isNull);
    });
  });

  group('isStorePackage', () {
    test('defaultsToFalse', () {
      expect(isStorePackage(), isFalse);
    });
  });

  group('legacyDesktopDataDir', () {
    test('emptyEnvironmentIsNull', () {
      setEnvironmentOverride({});
      expect(legacyDesktopDataDir(), isNull);
    });
  });
}
