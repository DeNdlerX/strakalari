import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

const aiStudioUrl = 'https://aistudio.google.com/apikey';
const releasesUrl = 'https://github.com/DeNdlerX/strakalari/releases';
const repoUrl = 'https://github.com/DeNdlerX/strakalari';

/// Opens ``url`` with the platform's default handler, the counterpart of
/// Python's `webbrowser.open`. Only desktop has one to call; elsewhere it
/// reports false.
Future<bool> _platformDefaultOpen(Uri uri) async {
  final url = uri.toString();
  if (Platform.isWindows) {
    final r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    return r.exitCode == 0;
  }
  if (Platform.isMacOS) {
    return (await Process.run('open', [url])).exitCode == 0;
  }
  if (Platform.isLinux) {
    return (await Process.run('xdg-open', [url])).exitCode == 0;
  }
  return false;
}

/// Opens an external URL in the system browser.
///
/// Port of `components.open_url`: try the normal launcher first; if it fails
/// (throws, or reports false, which is how url_launcher says it cannot),
/// fall back to the platform default so the link still opens on desktop.
/// Only the fallback's own failure is swallowed.
Future<bool> openUrl(String url,
    {Future<bool> Function(Uri uri)? launcher,
    Future<bool> Function(Uri uri)? fallback}) async {
  final clean = url.trim();
  if (clean.isEmpty) return false;
  final uri = Uri.tryParse(clean);
  if (uri == null) return false;
  try {
    final ok = launcher != null
        ? await launcher(uri)
        : await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok) return true;
  } catch (_) {
    // Fall through to the platform default, like Python's `except`.
  }
  try {
    return await (fallback ?? _platformDefaultOpen)(uri);
  } catch (_) {
    return false;
  }
}
