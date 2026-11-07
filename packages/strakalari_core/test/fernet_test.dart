import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:strakalari_core/src/storage/fernet.dart';

void main() {
  test('roundtrip', () {
    final fernet = Fernet.fromKeyBytes(Fernet.generateKey());
    const secret = 'Tajné heslo s diakritikou: Příliš žluťoučký kůň 123 ';
    final token = fernet.encryptBytes(utf8.encode(secret));
    expect(token, isNot(secret));
    expect(utf8.decode(fernet.decryptToken(token)), secret);
  });

  test('tokensCarryVersionAndTimestamp', () {
    final fernet = Fernet.fromKeyBytes(Fernet.generateKey());
    final raw = base64Url.decode(fernet.encryptBytes(utf8.encode('x')));
    expect(raw[0], 0x80);
    expect(raw.length, greaterThanOrEqualTo(73));
  });

  test('tamperedTokenThrows', () {
    final fernet = Fernet.fromKeyBytes(Fernet.generateKey());
    final token = fernet.encryptBytes(utf8.encode('heslo123'));
    final tampered =
        token.substring(0, token.length - 2) + (token.endsWith('A') ? 'BB' : 'AA');
    expect(() => fernet.decryptToken(tampered),
        throwsA(isA<InvalidTokenException>()));
  });

  test('wrongKeyThrows', () {
    final a = Fernet.fromKeyBytes(Fernet.generateKey());
    final b = Fernet.fromKeyBytes(Fernet.generateKey());
    final token = a.encryptBytes(utf8.encode('heslo123'));
    expect(() => b.decryptToken(token), throwsA(isA<InvalidTokenException>()));
  });

  test('garbageThrows', () {
    final fernet = Fernet.fromKeyBytes(Fernet.generateKey());
    expect(() => fernet.decryptToken('not_valid_base64_???!!!'),
        throwsA(isA<InvalidTokenException>()));
    expect(() => fernet.decryptToken(''), throwsA(isA<InvalidTokenException>()));
    expect(() => Fernet.fromKeyBytes(Uint8List(0)),
        throwsA(isA<InvalidTokenException>()));
    expect(Fernet.isValidKeyBytes(null), isFalse);
    expect(Fernet.isValidKeyBytes(Uint8List(0)), isFalse);
  });
}
