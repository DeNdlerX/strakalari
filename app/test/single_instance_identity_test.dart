// C-S1: the per-user identity, port slot and token are Python's
// (`_os_user`, `_user_slot`, `_valid_token`, `secrets.token_hex(16)` in
// flet_ui/single_instance.py). Expected values printed by Python with
// the same environment.
import 'package:app/platform/desktop/single_instance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('windowsIdentityKeepsTheUserNameCaseAndUsesUserprofile', () {
    final id = osUserIdentity(windows: true, env: {
      'USERNAME': 'Novak',
      'USERPROFILE': r'C:\Users\Novak',
      'HOME': '/c/Users/novak-git-bash', // ignored on Windows, like expanduser
    });
    expect(id, r'Novak|c:\users\novak');
    expect(userSlot(id), 140); // Python: _user_slot('Novak|c:\\users\\novak')
  });

  test('windowsWithoutUserprofileUsesHomedriveHomepath', () {
    expect(osUserIdentity(windows: true, env: {'USERNAME': 'A', 'HOMEDRIVE': 'D:', 'HOMEPATH': r'\Home\A'}),
        r'A|d:\home\a');
  });

  test('posixIdentityIsLognameAndHome', () {
    expect(osUserIdentity(windows: false, env: {'LOGNAME': 'Jan', 'USER': 'x', 'HOME': '/home/Jan'}),
        'Jan|/home/Jan');
  });

  test('tokensAreLowerCaseHexOnly', () {
    expect(validInstanceToken('0123456789abcdef0123456789abcdef'.codeUnits), isTrue);
    expect(validInstanceToken('0123456789ABCDEF0123456789abcdef'.codeUnits), isFalse);
    expect(validInstanceToken('0123456789abcdef'.codeUnits), isFalse);
  });

  test('randomTokensAreValidAndDiffer', () {
    final a = randomInstanceToken();
    final b = randomInstanceToken();
    expect(validInstanceToken(a), isTrue);
    expect(validInstanceToken(b), isTrue);
    expect(a, isNot(b));
  });
}
