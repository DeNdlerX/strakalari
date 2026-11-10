import 'package:url_launcher/url_launcher.dart';

const aiStudioUrl = 'https://aistudio.google.com/apikey';
const releasesUrl = 'https://github.com/DeNdlerX/strakalari/releases';

/// Opens an external URL in the system browser.
Future<bool> openUrl(String url,
    {Future<bool> Function(Uri uri)? launcher}) async {
  final clean = url.trim();
  if (clean.isEmpty) return false;
  final uri = Uri.tryParse(clean);
  if (uri == null) return false;
  try {
    if (launcher != null) {
      return await launcher(uri);
    }
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
