import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "strakalari/ios",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleIosMethodCall(call, result: result)
    }
    iosChannel = channel
  }

  private func handleIosMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "keychainGet":
      guard let service = args?["service"] as? String,
            let account = args?["account"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing service or account", details: nil))
        return
      }
      keychainGet(service: service, account: account, result: result)

    case "keychainSet":
      guard let service = args?["service"] as? String,
            let account = args?["account"] as? String,
            let value = args?["value"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing service, account, or value", details: nil))
        return
      }
      keychainSet(service: service, account: account, value: value, result: result)

    case "keychainDelete":
      guard let service = args?["service"] as? String,
            let account = args?["account"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing service or account", details: nil))
        return
      }
      keychainDelete(service: service, account: account, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func keychainGet(service: String, account: String, result: @escaping FlutterResult) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    guard status == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      result(FlutterError(
        code: "KEYCHAIN_READ_FAILED",
        message: "SecItemCopyMatching failed with OSStatus \(status)",
        details: Int(status)
      ))
      return
    }
    result(value)
  }

  /// Stores or updates a Keychain item with `AfterFirstUnlockThisDeviceOnly`
  /// accessibility so background refreshes can read the Fernet key while the
  /// device is locked after first unlock since boot.
  private func keychainSet(
    service: String,
    account: String,
    value: String,
    result: @escaping FlutterResult
  ) {
    guard let data = value.data(using: .utf8) else {
      result(FlutterError(code: "BAD_ARGS", message: "Invalid UTF-8 value", details: nil))
      return
    }
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributesToUpdate: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(addQuery as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      result(FlutterError(
        code: "KEYCHAIN_WRITE_FAILED",
        message: "Keychain write failed with OSStatus \(status)",
        details: Int(status)
      ))
      return
    }
    result(true)
  }

  private func keychainDelete(service: String, account: String, result: @escaping FlutterResult) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      result(FlutterError(
        code: "KEYCHAIN_DELETE_FAILED",
        message: "SecItemDelete failed with OSStatus \(status)",
        details: Int(status)
      ))
      return
    }
    result(true)
  }
}
