// MethodChannel client for the iOS platform side (`strakalari/ios`).
//
// Served by `AppDelegate.swift` using Apple's `Security` framework with
// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background refreshes
// can read the Fernet encryption key after the first unlock since boot.
import 'package:flutter/services.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// The channel `AppDelegate.swift` serves on iOS.
const String iosChannelName = 'strakalari/ios';

/// Typed client for the `strakalari/ios` MethodChannel.
class IosChannel {
  /// The shared UI-isolate channel.
  static const MethodChannel channel = MethodChannel(iosChannelName);

  final MethodChannel _channel;

  /// Wraps [_channel]; defaults to [channel].
  const IosChannel([this._channel = channel]);

  /// Reads a Keychain generic-password item. Returns `null` when absent.
  /// Throws [KeyStoreMissing] when no iOS plugin is registered and
  /// [KeyStoreUnavailable] when Keychain refuses access.
  Future<String?> keychainGet(String service, String account) async {
    try {
      return await _channel.invokeMethod<String>('keychainGet', {
        'service': service,
        'account': account,
      });
    } on MissingPluginException {
      throw const KeyStoreMissing('No iOS Keychain backend.');
    } on PlatformException catch (e) {
      throw KeyStoreUnavailable(
        'iOS Keychain read failed (${e.code}: ${e.message ?? ''}).',
      );
    }
  }

  /// Stores or updates a Keychain item with `AfterFirstUnlockThisDeviceOnly`
  /// accessibility so background reads work while the device is locked.
  Future<bool> keychainSet(
    String service,
    String account,
    String value,
  ) async {
    try {
      return await _channel.invokeMethod<bool>('keychainSet', {
            'service': service,
            'account': account,
            'value': value,
          }) ??
          false;
    } on MissingPluginException {
      throw const KeyStoreMissing('No iOS Keychain backend.');
    } on PlatformException catch (e) {
      throw KeyStoreUnavailable(
        'iOS Keychain write failed (${e.code}: ${e.message ?? ''}).',
      );
    }
  }

  /// Deletes a Keychain item if present. Silent when no backend is registered.
  Future<void> keychainDelete(String service, String account) async {
    try {
      await _channel.invokeMethod<void>('keychainDelete', {
        'service': service,
        'account': account,
      });
    } on MissingPluginException {
      // No backend off iOS.
    } on PlatformException catch (e) {
      throw KeyStoreUnavailable(
        'iOS Keychain delete failed (${e.code}: ${e.message ?? ''}).',
      );
    }
  }
}
