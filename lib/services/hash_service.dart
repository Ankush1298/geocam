import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provides Ed25519 asymmetric signing and verification for GeoCam photo records.
///
/// A random 32-byte seed is generated once per device installation and
/// stored in SharedPreferences. This acts as the Private Key.
class HashService {
  static const _prefKey = 'geocam_ed25519_seed_v1';
  
  static final _ed25519 = Ed25519();

  /// Returns the persisted device seed (private key), creating it on first launch.
  static Future<List<int>> _getSeed() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefKey);
    if (stored != null) {
      return base64Decode(stored);
    }
    // Generate a cryptographically random 32-byte seed.
    final rng = Random.secure();
    final seed = List<int>.generate(32, (_) => rng.nextInt(256));
    await prefs.setString(_prefKey, base64Encode(seed));
    return seed;
  }

  /// Builds the canonical UTF-8 message that is signed.
  static String _canonical({
    required String recordId,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required String address,
  }) {
    final lat = latitude != null ? latitude.toStringAsFixed(6) : 'null';
    final lng = longitude != null ? longitude.toStringAsFixed(6) : 'null';
    final acc = accuracy != null ? accuracy.toStringAsFixed(1) : 'null';
    return [
      'id=$recordId',
      'ts=${timestamp.toUtc().toIso8601String()}',
      'lat=$lat',
      'lng=$lng',
      'acc=$acc',
      'addr=$address',
    ].join('|');
  }

  /// Signs the record metadata and returns a Base64 signature.
  static Future<String> sign({
    required String recordId,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required String address,
  }) async {
    final seed = await _getSeed();
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    
    final msg = _canonical(
      recordId: recordId,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      address: address,
    );
    
    final signature = await _ed25519.sign(
      utf8.encode(msg),
      keyPair: keyPair,
    );
    
    // Return base64 encoded signature (approx 88 chars for 64 bytes)
    return base64Encode(signature.bytes);
  }

  /// Re-computes the key pair to extract public key and verifies the signature.
  /// (In a real system, the public key would be distributed or embedded, but here
  /// we verify locally just to check if the file was tampered with on-device).
  static Future<bool> verify({
    required String storedSignature,
    required String recordId,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required String address,
  }) async {
    if (storedSignature.isEmpty) return false;
    
    try {
      final seed = await _getSeed();
      final keyPair = await _ed25519.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      
      final msg = _canonical(
        recordId: recordId,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        address: address,
      );
      
      final signatureBytes = base64Decode(storedSignature);
      final signature = Signature(signatureBytes, publicKey: publicKey);
      
      final isVerified = await _ed25519.verify(
        utf8.encode(msg),
        signature: signature,
      );
      
      return isVerified;
    } catch (e) {
      return false; // Invalid base64 or other error
    }
  }

  /// Gets the public key in Base64 (could be useful for the verification server)
  static Future<String> getPublicKey() async {
    final seed = await _getSeed();
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }
}
