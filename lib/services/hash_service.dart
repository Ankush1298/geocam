import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
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

  static String _canonical({
    required String recordId,
    required String mediaType,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String mediaSha256,
  }) {
    final lat = latitude != null ? latitude.toStringAsFixed(6) : 'null';
    final lng = longitude != null ? longitude.toStringAsFixed(6) : 'null';
    final acc = accuracy != null ? accuracy.toStringAsFixed(1) : 'null';
    final alt = altitude != null ? altitude.toStringAsFixed(1) : 'null';
    final ts = timestamp.toUtc().toIso8601String();
    return [
      'v=2',
      'id=$recordId',
      'type=$mediaType',
      'ts=$ts',
      'lat=$lat',
      'lng=$lng',
      'acc=$acc',
      'alt=$alt',
      'addr64=${base64Encode(utf8.encode(address))}',
      'media_sha256=$mediaSha256',
    ].join('|');
  }

  static Future<String> sha256Bytes(Uint8List bytes) async =>
      crypto.sha256.convert(bytes).toString();

  static Future<String> sha256File(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<String> sign({
    required String recordId,
    required String mediaType,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String mediaSha256,
  }) async {
    final keyPair = await _keyPair();
    final msg = _canonical(
      recordId: recordId,
      mediaType: mediaType,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      altitude: altitude,
      address: address,
      mediaSha256: mediaSha256,
    );
    final signature = await _ed25519.sign(utf8.encode(msg), keyPair: keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<bool> verify({
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
  }) async {
    if (storedSignature.isEmpty || publicKey.isEmpty || mediaSha256.isEmpty) return false;
    try {
      final pub = SimplePublicKey(base64Decode(publicKey), type: KeyPairType.ed25519);
      final signature = Signature(base64Decode(storedSignature), publicKey: pub);
      final msg = _canonical(
        recordId: recordId,
        mediaType: mediaType,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        altitude: altitude,
        address: address,
        mediaSha256: mediaSha256,
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
