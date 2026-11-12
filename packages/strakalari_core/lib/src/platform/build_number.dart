// The Android versionCode for a release version.
//
// Port of `split_version` + `build_number` in tools/make_mobile.py: the
// Flet build stamped the versionCode this way, and a lower one can never
// install as an update over it.

/// `split_version`: `'0.2.0-beta.1'` → `([0, 2, 0], 'beta', 1)`; `'0.1.3'` → `([0, 1, 3], null, 0)`.
(List<int>, String?, int) _splitVersion(String version) {
  final m = RegExp(r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-(alpha|beta|rc)\.?(\d+))?$')
      .firstMatch(version.trim());
  if (m == null) {
    throw FormatException(
        "version must look like 1.2.3 or 1.2.3-beta.1, got '$version'");
  }
  return (
    [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3) ?? '0')],
    m.group(4),
    int.parse(m.group(5) ?? '0'),
  );
}

/// Android versionCode: must grow with every release, betas included.
///
/// The last two digits order the pre-releases of one version: alpha
/// 1–29, beta 31–59, rc 61–89, the stable release 99 (it sorts after its
/// pre-releases, like the in-app update check). 0.1.3 → 10399,
/// 0.2.0-beta.1 → 20031, 0.2.0-rc.1 → 20061, 0.2.0 → 20099.
int buildNumber(String version) {
  final (parts, kind, num) = _splitVersion(version);
  final [major, minor, patch] = parts;
  if (minor > 99 || patch > 99 || num > 29) {
    throw FormatException("version '$version' does not fit the build-number scheme");
  }
  final slot = kind == null ? 99 : const {'alpha': 0, 'beta': 30, 'rc': 60}[kind]! + num;
  return ((major * 100 + minor) * 100 + patch) * 100 + slot;
}
