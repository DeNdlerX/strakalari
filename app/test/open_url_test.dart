import 'package:app/features/common/open_url.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port of `tests/test_open_url.py` (runtime url launching).
void main() {
  test('openUrlAwaitsLaunchUrl', () async {
    final opened = <Uri>[];
    final ok = await openUrl(
      aiStudioUrl,
      launcher: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(ok, isTrue);
    expect(opened, [Uri.parse(aiStudioUrl)]);
  });

  test('openUrlFallsBack', () async {
    final ok = await openUrl(
      aiStudioUrl,
      launcher: (uri) async {
        throw StateError('cannot open URL');
      },
    );
    expect(ok, isFalse);
  });

  test('openUrlIgnoresEmpty', () async {
    final opened = <Uri>[];
    final ok = await openUrl(
      '',
      launcher: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(ok, isFalse);
    expect(opened, isEmpty);
  });
}
