// Port of `TestMakeMobile.test_build_numbers_grow` (tests/test_mobile.py)
// and the examples in `build_number`'s docstring (tools/make_mobile.py).
import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

void main() {
  test('buildNumbersGrow', () {
    const order = ['0.1.3', '0.2.0-alpha.3', '0.2.0-beta.1', '0.2.0-beta.2', '0.2.0-rc.1',
        '0.2.0', '1.0.0'];
    final numbers = [for (final v in order) buildNumber(v)];
    expect(numbers, [...numbers]..sort());
    expect(numbers.toSet().length, numbers.length);
  });

  test('docstringExamples', () {
    expect(buildNumber('0.1.3'), 10399);
    expect(buildNumber('0.2.0-beta.1'), 20031);
    expect(buildNumber('0.2.0-rc.1'), 20061);
    expect(buildNumber('0.2.0'), 20099);
    expect(buildNumber('v0.1'), 10099);
    expect(buildNumber('0.1.0'), 10099);
  });

  test('versionsOutsideTheSchemeAreRefused', () {
    expect(() => buildNumber('0.100.0'), throwsFormatException);
    expect(() => buildNumber('0.1.0-beta.30'), throwsFormatException);
    expect(() => buildNumber('nightly'), throwsFormatException);
  });
}
