import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geocam/services/fingerprint_service.dart';
import 'package:geocam/services/hash_service.dart';
import 'package:geocam/services/luma_fingerprint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  // Helper to generate a test JPEG image of given dimensions and background color
  Uint8List makeTestJpeg(int width, int height, {img.Color? color}) {
    final image = img.Image(width: width, height: height);
    final fill = color ?? img.ColorRgb8(100, 150, 200);
    img.fill(image, color: fill);

    // Draw some distinct patterns so each region is unique
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if ((x + y) % 7 == 0) {
          image.setPixel(x, y, img.ColorRgb8(x % 256, y % 256, (x * y) % 256));
        }
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  group('FingerprintService - Region Generation & Manifest', () {
    test('generate produces deterministic 8x8 region manifest', () async {
      final jpg = makeTestJpeg(128, 128);
      final manifest1 = await FingerprintService.generate(jpg, gridRows: 8, gridCols: 8);
      final manifest2 = await FingerprintService.generate(jpg, gridRows: 8, gridCols: 8);

      expect(manifest1, isNotNull);
      expect(manifest2, isNotNull);
      expect(manifest1!.imageWidth, 128);
      expect(manifest1.imageHeight, 128);
      expect(manifest1.gridRows, 8);
      expect(manifest1.gridCols, 8);
      expect(manifest1.regions.length, 64);

      // Determinism
      expect(manifest1.toCanonicalJson(), equals(manifest2!.toCanonicalJson()));
      expect(manifest1.sha256Digest, equals(manifest2.sha256Digest));
    });

    test('manifest canonical JSON matches expected format and sorts keys alphabetically', () async {
      final jpg = makeTestJpeg(64, 64);
      final manifest = await FingerprintService.generate(jpg, gridRows: 2, gridCols: 2);
      expect(manifest, isNotNull);

      final jsonStr = manifest!.toCanonicalJson();
      // Keys must be in order: algorithm, fpVersion, gridCols, gridRows, imageHeight, imageWidth, regions
      final keyOrder = ['"algorithm"', '"fpVersion"', '"gridCols"', '"gridRows"', '"imageHeight"', '"imageWidth"', '"regions"'];
      var lastIndex = -1;
      for (final key in keyOrder) {
        final idx = jsonStr.indexOf(key);
        expect(idx, greaterThan(lastIndex), reason: '$key should appear in alphabetical order');
        lastIndex = idx;
      }
    });
  });

  group('FingerprintService - Verification Layers', () {
    test('Layer A: exact original photo passes exact-file verification', () async {
      final originalJpg = makeTestJpeg(128, 128);
      final expectedSha = crypto.sha256.convert(originalJpg).toString();
      final manifest = await FingerprintService.generate(originalJpg, gridRows: 4, gridCols: 4);

      final result = await FingerprintService.verify(
        receivedBytes: originalJpg,
        expectedMediaSha256: expectedSha,
        signatureValid: true,
        manifest: manifest,
      );

      expect(result.outcome, VerificationOutcome.exactMatch);
      expect(result.isAuthentic, isTrue);
      expect(result.exactFileMatch, isTrue);
      expect(result.regionCheckPassed, isTrue);
      expect(result.matchingRegions, 16);
      expect(result.totalRegions, 16);
    });

    test('Layer A & B: 1-pixel modification fails exact-file and is flagged in region analysis', () async {
      final originalJpg = makeTestJpeg(128, 128);
      final expectedSha = crypto.sha256.convert(originalJpg).toString();
      final manifest = await FingerprintService.generate(originalJpg, gridRows: 4, gridCols: 4, algorithm: RegionFingerprintManifest.legacyAlgorithm);

      // Decode, modify 1 pixel in top-left region (0, 0), and re-encode
      final decoded = img.decodeImage(originalJpg)!;
      decoded.setPixel(2, 2, img.ColorRgb8(255, 0, 0));
      final tamperedJpg = Uint8List.fromList(img.encodeJpg(decoded, quality: 90));

      final result = await FingerprintService.verify(
        receivedBytes: tamperedJpg,
        expectedMediaSha256: expectedSha,
        signatureValid: true,
        manifest: manifest,
      );

      expect(result.outcome, VerificationOutcome.modificationDetected);
      expect(result.isAuthentic, isFalse);
      expect(result.exactFileMatch, isFalse);
      expect(result.regionCheckPassed, isFalse);
      expect(result.regionMatches, isNotNull);
      // Top-left region (0, 0) should fail
      expect(result.regionMatches![0], isFalse);
    });

    test('Layer B: Cropping image reduces dimensions and is flagged as cropping modification', () async {
      final originalJpg = makeTestJpeg(128, 128);
      final expectedSha = crypto.sha256.convert(originalJpg).toString();
      final manifest = await FingerprintService.generate(originalJpg, gridRows: 4, gridCols: 4);

      // Crop 16 pixels off the right side (112x128)
      final decoded = img.decodeImage(originalJpg)!;
      final cropped = img.copyCrop(decoded, x: 0, y: 0, width: 112, height: 128);
      final croppedJpg = Uint8List.fromList(img.encodeJpg(cropped, quality: 90));

      final result = await FingerprintService.verify(
        receivedBytes: croppedJpg,
        expectedMediaSha256: expectedSha,
        signatureValid: true,
        manifest: manifest,
      );

      expect(result.outcome, VerificationOutcome.modificationDetected);
      expect(result.exactFileMatch, isFalse);
      expect(result.regionCheckPassed, isFalse);
      expect(result.summary, contains('Framing differs'));
      expect(result.regionMatches, isNull); // no made-up edit locations for an unaligned crop
      expect(result.originalDimensions, '128x128');
      expect(result.testedDimensions, '112x128');
    });

    test('No image supplied returns RECORD AUTHENTIC, IMAGE UNCHECKED', () async {
      final manifest = RegionFingerprintManifest(
        imageWidth: 100,
        imageHeight: 100,
        regions: List.filled(16, 'hash'),
      );

      final result = await FingerprintService.verify(
        receivedBytes: null,
        expectedMediaSha256: 'someexpectedsha',
        signatureValid: true,
        manifest: manifest,
      );

      expect(result.outcome, VerificationOutcome.recordAuthenticImageUnchecked);
      expect(result.signatureValid, isTrue);
      expect(result.exactFileMatch, isFalse);
      expect(result.isAuthentic, isFalse);
    });

    test('Invalid digital signature immediately returns INVALID SIGNATURE', () async {
      final jpg = makeTestJpeg(64, 64);
      final result = await FingerprintService.verify(
        receivedBytes: jpg,
        expectedMediaSha256: crypto.sha256.convert(jpg).toString(),
        signatureValid: false,
      );

      expect(result.outcome, VerificationOutcome.invalidSignature);
      expect(result.signatureValid, isFalse);
      expect(result.isAuthentic, isFalse);
    });

    test('Malformed image bytes return UNABLE TO VERIFY', () async {
      final garbage = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final manifest = RegionFingerprintManifest(
        algorithm: RegionFingerprintManifest.legacyAlgorithm,
        imageWidth: 64,
        imageHeight: 64,
        regions: List.filled(64, 'hash'),
      );

      final result = await FingerprintService.verify(
        receivedBytes: garbage,
        expectedMediaSha256: 'differenthash',
        signatureValid: true,
        manifest: manifest,
      );

      expect(result.outcome, VerificationOutcome.unableToVerify);
    });
  });

  group('HashService - v2 and v3 canonical signatures', () {
    test('v3 signature with image dimensions and fingerprint round-trips correctly', () async {
      final recordId = 'GC-TEST-V3-001';
      final ts = DateTime.utc(2026, 10, 3, 16, 12, 10);
      final mediaSha = crypto.sha256.convert([1, 2, 3]).toString();
      final fpSha = crypto.sha256.convert([4, 5, 6]).toString();
      final imgDim = '3024x4032';

      final sig = await HashService.sign(
        proto: 3,
        recordId: recordId,
        mediaType: 'photo',
        timestamp: ts,
        latitude: 25.033919,
        longitude: 74.634770,
        accuracy: 10.0,
        altitude: 400.0,
        address: 'Test City',
        mediaSha256: mediaSha,
        imageDimensions: imgDim,
        fpVersion: 1,
        fpSha256: fpSha,
      );
      expect(sig, isNotEmpty);

      final pubKey = await HashService.getPublicKey();
      final ok = await HashService.verify(
        proto: 3,
        storedSignature: sig,
        publicKey: pubKey,
        recordId: recordId,
        mediaType: 'photo',
        timestamp: ts,
        latitude: 25.033919,
        longitude: 74.634770,
        accuracy: 10.0,
        altitude: 400.0,
        address: 'Test City',
        mediaSha256: mediaSha,
        imageDimensions: imgDim,
        fpVersion: 1,
        fpSha256: fpSha,
      );
      expect(ok, isTrue);

      // Tampering any v3 field must invalidate the signature
      final badSig = await HashService.verify(
        proto: 3,
        storedSignature: sig,
        publicKey: pubKey,
        recordId: recordId,
        mediaType: 'photo',
        timestamp: ts,
        latitude: 25.033919,
        longitude: 74.634770,
        accuracy: 10.0,
        altitude: 400.0,
        address: 'Test City',
        mediaSha256: mediaSha,
        imageDimensions: '1000x1000', // Tampered dimensions
        fpVersion: 1,
        fpSha256: fpSha,
      );
      expect(badSig, isFalse);
    });
  });

  group('Additional integrity cases', () {
    test('resized copy is consistent but never EXACT MATCH', () async {
      final jpg = makeTestJpeg(128, 128);
      final manifest = await FingerprintService.generate(jpg, gridRows: 4, gridCols: 4);
      final small = img.copyResize(img.decodeImage(jpg)!, width: 64, height: 64);
      final r = await FingerprintService.verify(
        receivedBytes: Uint8List.fromList(img.encodeJpg(small)),
        expectedMediaSha256: crypto.sha256.convert(jpg).toString(),
        signatureValid: true,
        manifest: manifest,
      );
      expect(r.isAuthentic, isFalse);
      expect(r.exactFileMatch, isFalse);
    });

    test('recompressed same-size copy is not an exact match', () async {
      final jpg = makeTestJpeg(128, 128);
      final manifest = await FingerprintService.generate(jpg, gridRows: 4, gridCols: 4);
      final re = Uint8List.fromList(img.encodeJpg(img.decodeImage(jpg)!, quality: 60));
      final r = await FingerprintService.verify(
        receivedBytes: re,
        expectedMediaSha256: crypto.sha256.convert(jpg).toString(),
        signatureValid: true,
        manifest: manifest,
      );
      expect(r.exactFileMatch, isFalse);
      expect(r.isAuthentic, isFalse);
    });

    test('pixels identical but file bytes differ is NOT an exact match', () async {
      final jpg = makeTestJpeg(64, 64);
      final manifest = await FingerprintService.generate(jpg, gridRows: 2, gridCols: 2);
      final r = await FingerprintService.verify(
        receivedBytes: Uint8List.fromList([...jpg, 0]),
        expectedMediaSha256: crypto.sha256.convert(jpg).toString(),
        signatureValid: true,
        manifest: manifest,
      );
      expect(r.exactFileMatch, isFalse);
      expect(r.isAuthentic, isFalse);
    });

    test('unsupported algorithm or oversized grid is inconclusive, not a pass', () async {
      final jpg = makeTestJpeg(64, 64);
      final bad = RegionFingerprintManifest(
        algorithm: 'unknown-v9', imageWidth: 64, imageHeight: 64, regions: ['x'],
        gridRows: 1, gridCols: 1);
      expect(bad.isWellFormed, isFalse);
      final huge = RegionFingerprintManifest(
        imageWidth: 64, imageHeight: 64, gridRows: 100000, gridCols: 100000, regions: []);
      expect(huge.isWellFormed, isFalse);
      final r = await FingerprintService.verify(
        receivedBytes: jpg,
        expectedMediaSha256: 'f' * 64,
        signatureValid: true,
        manifest: bad,
      );
      expect(r.isAuthentic, isFalse);
      expect(r.regionCheckPassed, isNull);
    });

    test('tampered record fields fail local signature verification', () async {
      final ts = DateTime.utc(2026, 10, 3, 16, 12, 10);
      final sha = crypto.sha256.convert([1]).toString();
      final sig = await HashService.sign(
        recordId: 'GC-X', mediaType: 'photo', timestamp: ts, latitude: 1, longitude: 2,
        accuracy: 3, altitude: 4, address: 'a', mediaSha256: sha);
      final pub = await HashService.getPublicKey();
      Future<bool> check(String sha256) => HashService.verify(
        storedSignature: sig, publicKey: pub, recordId: 'GC-X', mediaType: 'photo',
        timestamp: ts, latitude: 1, longitude: 2, accuracy: 3, altitude: 4,
        address: 'a', mediaSha256: sha256);
      expect(await check(sha), isTrue);
      expect(await check(crypto.sha256.convert([2]).toString()), isFalse);
    });
  });

  group('Tolerant luma fingerprints (grid-luma-v2)', () {
    // Deterministic random 8px colour blocks: every tile has real structure.
    img.Image blocky(int size, int seed) {
      final image = img.Image(width: size, height: size);
      var state = seed;
      int next() {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        return state;
      }
      for (var by = 0; by < size ~/ 8; by++) {
        for (var bx = 0; bx < size ~/ 8; bx++) {
          final c = img.ColorRgb8(next() % 256, next() % 256, next() % 256);
          for (var y = 0; y < 8; y++) {
            for (var x = 0; x < 8; x++) {
              image.setPixel(bx * 8 + x, by * 8 + y, c);
            }
          }
        }
      }
      return image;
    }

    Uint8List jpg(img.Image i, {int q = 95}) => Uint8List.fromList(img.encodeJpg(i, quality: q));

    Future<(Uint8List, String, RegionFingerprintManifest)> original() async {
      final bytes = jpg(blocky(256, 7));
      final m = await FingerprintService.generate(bytes);
      return (bytes, crypto.sha256.convert(bytes).toString(), m!);
    }

    Future<VerificationResult> check(Uint8List received, String sha, RegionFingerprintManifest m) =>
        FingerprintService.verify(receivedBytes: received, expectedMediaSha256: sha, signatureValid: true, manifest: m);

    test('manifest is v2, well formed, and tiles round-trip', () async {
      final (_, _, m) = await original();
      expect(m.algorithm, lumaAlgorithm);
      expect(m.fpVersion, 2);
      expect(m.isWellFormed, isTrue);
      expect(Tile.parse(m.regions.first).toString(), m.regions.first);
    });

    test('recompression is consistent, not an exact match', () async {
      final (bytes, sha, m) = await original();
      final r = await check(jpg(img.decodeImage(bytes)!, q: 50), sha, m);
      expect(r.outcome, VerificationOutcome.reencodedContentConsistent);
      expect(r.exactFileMatch, isFalse);
      expect(r.isAuthentic, isFalse);
    });

    test('downscaled copy is consistent', () async {
      final (bytes, sha, m) = await original();
      final small = img.copyResize(img.decodeImage(bytes)!, width: 128, height: 128);
      final r = await check(jpg(small, q: 80), sha, m);
      expect(r.outcome, VerificationOutcome.reencodedContentConsistent);
      expect(r.testedDimensions, '128x128');
    });

    test('a pasted-over patch is flagged on the right tiles', () async {
      final (bytes, sha, m) = await original();
      final edited = img.decodeImage(bytes)!;
      img.fillRect(edited, x1: 70, y1: 70, x2: 110, y2: 110, color: img.ColorRgb8(255, 255, 255));
      final r = await check(jpg(edited), sha, m);
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.regionMatches![0], isTrue); // far corner untouched
      expect(r.regionMatches![2 * 8 + 2], isFalse); // tile (row 2, col 2) holds the patch
    });

    test('brightness change is flagged', () async {
      final (bytes, sha, m) = await original();
      final bright = img.adjustColor(img.decodeImage(bytes)!, brightness: 1.5);
      final r = await check(jpg(bright), sha, m);
      expect(r.outcome, VerificationOutcome.modificationDetected);
    });

    test('grid-aligned crop is located', () async {
      final (bytes, sha, m) = await original();
      final cropped = img.copyCrop(img.decodeImage(bytes)!, x: 64, y: 0, width: 192, height: 256);
      final r = await check(jpg(cropped), sha, m);
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.summary, contains('columns 3-8'));
    });

    test('unaligned crop is flagged without claiming a location', () async {
      final (bytes, sha, m) = await original();
      final cropped = img.copyCrop(img.decodeImage(bytes)!, x: 13, y: 5, width: 200, height: 240);
      final r = await check(jpg(cropped), sha, m);
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.isAuthentic, isFalse);
    });

    test('a different photo is flagged', () async {
      final (_, sha, m) = await original();
      final r = await check(jpg(blocky(256, 99)), sha, m);
      expect(r.outcome, VerificationOutcome.modificationDetected);
    });

    test('tampered tile strings make the manifest malformed', () {
      final m = RegionFingerprintManifest(
          imageWidth: 8, imageHeight: 8, gridRows: 1, gridCols: 1, regions: ['not-a-tile']);
      expect(m.isWellFormed, isFalse);
    });
  });
}
