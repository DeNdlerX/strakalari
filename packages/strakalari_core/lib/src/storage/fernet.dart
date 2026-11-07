// Minimal Fernet token implementation for stored secrets.
//
// Mirrors the `cryptography.fernet` behaviour helpers/secret_store rely on:
// AES-128-CBC with PKCS7 padding, HMAC-SHA256 authentication, 64-bit
// timestamp + 16-byte IV, URL-safe base64. Interoperates byte-for-byte
// with tokens Python wrote (proven by the cross-implementation check in
// the phase-1 notes) and decrypts anything Python's Fernet produced.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Thrown when a token (or key) is malformed, tampered or cut for the
/// wrong key. Mirrors `cryptography.fernet.InvalidToken`.
class InvalidTokenException implements Exception {
  final String message;
  const InvalidTokenException([this.message = 'Invalid Fernet token.']);

  @override
  String toString() => 'InvalidTokenException: $message';
}

/// A Fernet instance bound to one 32-byte key (16 signing + 16 encryption).
class Fernet {
  final Uint8List _signingKey;
  final Uint8List _encryptionKey;

  Fernet._(this._signingKey, this._encryptionKey);

  /// Parses a raw Fernet key (the ASCII base64 form `secret.key` holds).
  /// Throws [InvalidTokenException] when it is not a usable key — the
  /// same cases Python's `Fernet(key)` constructor rejects.
  factory Fernet.fromKeyBytes(Uint8List asciiKey) {
    Uint8List raw;
    try {
      raw = Uint8List.fromList(base64Url.decode(ascii.decode(asciiKey)));
    } on FormatException catch (e) {
      throw InvalidTokenException('Key is not base64: $e');
    }
    if (raw.length != 32) {
      throw const InvalidTokenException('Key must be 32 url-safe '
          'base64-encoded bytes.');
    }
    return Fernet._(raw.sublist(0, 16), raw.sublist(16, 32));
  }

  /// A fresh random key in the ASCII base64 file form.
  static Uint8List generateKey() {
    final random = Random.secure();
    final raw = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
    return ascii.encode(base64Url.encode(raw));
  }

  /// True when [asciiKey] parses as a usable Fernet key.
  static bool isValidKeyBytes(Uint8List? asciiKey) {
    if (asciiKey == null || asciiKey.isEmpty) return false;
    try {
      Fernet.fromKeyBytes(asciiKey);
      return true;
    } on InvalidTokenException {
      return false;
    }
  }

  /// Encrypts [plain] into the ASCII token form.
  String encryptBytes(Uint8List plain) {
    final iv = Uint8List.fromList(List<int>.generate(
        16, (_) => Random.secure().nextInt(256)));
    final timestamp = clock.now().millisecondsSinceEpoch ~/ 1000;
    final header = Uint8List(9)
      ..[0] = 0x80
      ..buffer.asByteData().setUint64(1, timestamp);
    final cipher = _cbc(true, iv, _pad(plain));
    final hmac = _mac([...header, ...iv, ...cipher]);
    return base64Url.encode([...header, ...iv, ...cipher, ...hmac]);
  }

  /// Decrypts an ASCII token. Throws [InvalidTokenException] on tampering,
  /// truncation or a wrong key (never returns garbage).
  Uint8List decryptToken(String token) {
    Uint8List raw;
    try {
      raw = Uint8List.fromList(base64Url.decode(token));
    } on FormatException catch (e) {
      throw InvalidTokenException('Token is not base64: $e');
    }
    // Version + timestamp + IV + one AES block + HMAC at minimum.
    if (raw.length < 73 || raw[0] != 0x80) {
      throw const InvalidTokenException('Token has a bad shape.');
    }
    final iv = raw.sublist(9, 25);
    final cipher = raw.sublist(25, raw.length - 32);
    final mac = raw.sublist(raw.length - 32);
    if (cipher.isEmpty || cipher.length % 16 != 0) {
      throw const InvalidTokenException('Token has a bad shape.');
    }
    if (!_constantTimeEquals(_mac(raw.sublist(0, raw.length - 32)), mac)) {
      throw const InvalidTokenException('Token signature mismatch.');
    }
    return _unpad(_cbc(false, iv, cipher));
  }

  Uint8List _mac(List<int> data) =>
      Uint8List.fromList(Hmac(sha256, _signingKey).convert(data).bytes);

  Uint8List _cbc(bool encrypt, Uint8List iv, Uint8List data) {
    final cbc = CBCBlockCipher(AESEngine())
      ..init(encrypt, ParametersWithIV(KeyParameter(_encryptionKey), iv));
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 16) {
      final processed = cbc.processBlock(data, off, out, off);
      assert(processed == 16);
    }
    return out;
  }

  static Uint8List _pad(Uint8List data) {
    final padLen = 16 - (data.length % 16);
    final out = Uint8List(data.length + padLen)..setAll(0, data);
    out.fillRange(data.length, out.length, padLen);
    return out;
  }

  static Uint8List _unpad(Uint8List data) {
    if (data.isEmpty || data.length % 16 != 0) {
      throw const InvalidTokenException('Bad padding.');
    }
    final padLen = data.last;
    if (padLen < 1 || padLen > 16) {
      throw const InvalidTokenException('Bad padding.');
    }
    for (var i = data.length - padLen; i < data.length; i++) {
      if (data[i] != padLen) {
        throw const InvalidTokenException('Bad padding.');
      }
    }
    return data.sublist(0, data.length - padLen);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
