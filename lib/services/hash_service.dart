import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local Ed25519 identity and capture signing service.
///
/// The private seed is stored in platform secure storage. The server receives
/// only the public key. A v2 signature covers the canonical capture metadata
/// AND the SHA-256 digest of the final media bytes.
class HashService {
  static const _seedKey = 'geocam_ed25519_seed_v2';
  static final _ed25519 = Ed25519();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<List<int>> _getSeed() async {
    final stored = await _storage.read(key: _seedKey);
    if (stored != null) {
      final seed = base64Decode(stored);
      if (seed.length == 32) return seed;
    }
    final rng = Random.secure();
    final seed = List<int>.generate(32, (_) => rng.nextInt(256));
    await _storage.write(key: _seedKey, value: base64Encode(seed));
    return seed;
  }

  static Future<SimpleKeyPair> _keyPair() async {
    return _ed25519.newKeyPairFromSeed(await _getSeed());
  }

  /// The exact string that is signed. Must stay byte-identical to the server's
  /// `canonical()` in app.py (pinned by a shared golden vector in both test suites).
  @visibleForTesting
  static String canonicalMessage({
    int proto = 2,
    required String recordId,
    required String mediaType,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String mediaSha256,
    String? imageDimensions,
    int fpVersion = 0,
    String? fpSha256,
  }) {
    final lat = latitude != null ? latitude.toStringAsFixed(6) : 'null';
    final lng = longitude != null ? longitude.toStringAsFixed(6) : 'null';
    final acc = accuracy != null ? accuracy.toStringAsFixed(1) : 'null';
    final alt = altitude != null ? altitude.toStringAsFixed(1) : 'null';
    final ts = timestamp.toUtc().toIso8601String();
    final parts = [
      'v=$proto',
      'id=$recordId',
      'type=$mediaType',
      'ts=$ts',
      'lat=$lat',
      'lng=$lng',
      'acc=$acc',
      'alt=$alt',
      'addr64=${base64Encode(utf8.encode(address))}',
      'media_sha256=$mediaSha256',
    ];
    if (proto >= 3) {
      parts.addAll([
        'img=${imageDimensions ?? ""}',
        'fp_version=$fpVersion',
        'fp_sha256=${fpSha256 ?? ""}',
      ]);
    }
    return parts.join('|');
  }

  static Future<String> sha256Bytes(Uint8List bytes) async =>
      crypto.sha256.convert(bytes).toString();

  static Future<String> sha256File(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<String> sign({
    int proto = 2,
    required String recordId,
    required String mediaType,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String mediaSha256,
    String? imageDimensions,
    int fpVersion = 0,
    String? fpSha256,
  }) async {
    final effectiveProto = (proto >= 3 || (fpVersion > 0) || (imageDimensions != null && imageDimensions.isNotEmpty)) ? 3 : 2;
    final keyPair = await _keyPair();
    final msg = canonicalMessage(
      proto: effectiveProto,
      recordId: recordId,
      mediaType: mediaType,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      altitude: altitude,
      address: address,
      mediaSha256: mediaSha256,
      imageDimensions: imageDimensions,
      fpVersion: fpVersion,
      fpSha256: fpSha256,
    );
    final signature = await _ed25519.sign(utf8.encode(msg), keyPair: keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<bool> verify({
    int proto = 2,
    required String storedSignature,
    required String publicKey,
    required String recordId,
    required String mediaType,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String mediaSha256,
    String? imageDimensions,
    int fpVersion = 0,
    String? fpSha256,
  }) async {
    if (storedSignature.isEmpty || publicKey.isEmpty || mediaSha256.isEmpty) return false;
    try {
      final pub = SimplePublicKey(base64Decode(publicKey), type: KeyPairType.ed25519);
      final signature = Signature(base64Decode(storedSignature), publicKey: pub);
      final msg = canonicalMessage(
        proto: proto,
        recordId: recordId,
        mediaType: mediaType,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        altitude: altitude,
        address: address,
        mediaSha256: mediaSha256,
        imageDimensions: imageDimensions,
        fpVersion: fpVersion,
        fpSha256: fpSha256,
      );
      return await _ed25519.verify(utf8.encode(msg), signature: signature);
    } catch (_) {
      return false;
    }
  }

  static Future<String> getPublicKey() async {
    final publicKey = await (await _keyPair()).extractPublicKey();
    return base64Encode(publicKey.bytes);
  }
}
