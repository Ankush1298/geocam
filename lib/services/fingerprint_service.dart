import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

/// Outcome classifications required by the GeoCam privacy-first specification.
enum VerificationOutcome {
  exactMatch,
  modificationDetected,
  recordAuthenticImageUnchecked,
  unableToVerify,
  invalidSignature;

  String get label {
    switch (this) {
      case VerificationOutcome.exactMatch:
        return 'EXACT MATCH';
      case VerificationOutcome.modificationDetected:
        return 'MODIFICATION DETECTED';
      case VerificationOutcome.recordAuthenticImageUnchecked:
        return 'RECORD AUTHENTIC, IMAGE UNCHECKED';
      case VerificationOutcome.unableToVerify:
        return 'UNABLE TO VERIFY';
      case VerificationOutcome.invalidSignature:
        return 'INVALID SIGNATURE';
    }
  }
}

/// Detailed result of evaluating a received image against a signed record.
class VerificationResult {
  final VerificationOutcome outcome;
  final bool signatureValid;
  final bool exactFileMatch;
  final bool? regionCheckPassed;
  final int matchingRegions;
  final int totalRegions;
  final String? originalDimensions;
  final String? testedDimensions;
  final String summary;
  final String details;
  final List<bool>? regionMatches;

  const VerificationResult({
    required this.outcome,
    required this.signatureValid,
    required this.exactFileMatch,
    this.regionCheckPassed,
    this.matchingRegions = 0,
    this.totalRegions = 0,
    this.originalDimensions,
    this.testedDimensions,
    required this.summary,
    required this.details,
    this.regionMatches,
  });

  bool get isAuthentic => outcome == VerificationOutcome.exactMatch;
}

/// Authenticated region fingerprint manifest (Layer B).
class RegionFingerprintManifest {
  static const defaultGridRows = 8;
  static const defaultGridCols = 8;
  static const defaultAlgorithm = 'grid-sha256-v1';

  final int fpVersion;
  final String algorithm;
  final int imageWidth;
  final int imageHeight;
  final int gridRows;
  final int gridCols;
  final List<String> regions;

  const RegionFingerprintManifest({
    this.fpVersion = 1,
    this.algorithm = defaultAlgorithm,
    required this.imageWidth,
    required this.imageHeight,
    this.gridRows = defaultGridRows,
    this.gridCols = defaultGridCols,
    required this.regions,
  });

  /// Canonical JSON representation with alphabetically sorted keys.
  /// Exactly matches the server-side canonicalization in app.py.
  String toCanonicalJson() {
    final buffer = StringBuffer();
    buffer.write('{');
    buffer.write('"algorithm":${jsonEncode(algorithm)},');
    buffer.write('"fpVersion":$fpVersion,');
    buffer.write('"gridCols":$gridCols,');
    buffer.write('"gridRows":$gridRows,');
    buffer.write('"imageHeight":$imageHeight,');
    buffer.write('"imageWidth":$imageWidth,');
    buffer.write('"regions":[');
    for (var i = 0; i < regions.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(jsonEncode(regions[i]));
    }
    buffer.write(']}');
    return buffer.toString();
  }

  /// Bounds check so a hostile manifest cannot cause huge loops.
  bool get isWellFormed =>
      algorithm == defaultAlgorithm &&
      gridRows > 0 && gridRows <= 64 && gridCols > 0 && gridCols <= 64 &&
      regions.length == gridRows * gridCols &&
      imageWidth > 0 && imageHeight > 0;

  /// SHA-256 of the canonical JSON string.
  String get sha256Digest =>
      crypto.sha256.convert(utf8.encode(toCanonicalJson())).toString();

  factory RegionFingerprintManifest.fromJson(Map<String, dynamic> json) {
    return RegionFingerprintManifest(
      fpVersion: (json['fpVersion'] as num?)?.toInt() ?? 1,
      algorithm: (json['algorithm'] as String?) ?? defaultAlgorithm,
      imageWidth: (json['imageWidth'] as num).toInt(),
      imageHeight: (json['imageHeight'] as num).toInt(),
      gridRows: (json['gridRows'] as num?)?.toInt() ?? defaultGridRows,
      gridCols: (json['gridCols'] as num?)?.toInt() ?? defaultGridCols,
      regions: (json['regions'] as List).map((e) => e.toString()).toList(),
    );
  }

  static RegionFingerprintManifest? parseJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return RegionFingerprintManifest.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }
}

/// Service to generate and verify image region fingerprints (Layer B).
class FingerprintService {
  /// Compute region fingerprints over image bytes.
  static Future<RegionFingerprintManifest?> generate(
    Uint8List imageBytes, {
    int gridRows = RegionFingerprintManifest.defaultGridRows,
    int gridCols = RegionFingerprintManifest.defaultGridCols,
  }) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      final width = image.width;
      final height = image.height;
      final regions = <String>[];

      for (var r = 0; r < gridRows; r++) {
        final y0 = (r * height) ~/ gridRows;
        final y1 = ((r + 1) * height) ~/ gridRows;
        final h = y1 - y0;

        for (var c = 0; c < gridCols; c++) {
          final x0 = (c * width) ~/ gridCols;
          final x1 = ((c + 1) * width) ~/ gridCols;
          final w = x1 - x0;

          final crop = img.copyCrop(image, x: x0, y: y0, width: w, height: h);
          final digest = crypto.sha256.convert(crop.toUint8List()).toString();
          regions.add(digest);
        }
      }

      return RegionFingerprintManifest(
        fpVersion: 1,
        algorithm: RegionFingerprintManifest.defaultAlgorithm,
        imageWidth: width,
        imageHeight: height,
        gridRows: gridRows,
        gridCols: gridCols,
        regions: regions,
      );
    } catch (_) {
      return null;
    }
  }

  /// Perform Layer A and Layer B local verification.
  static Future<VerificationResult> verify({
    required Uint8List? receivedBytes,
    required String expectedMediaSha256,
    required bool signatureValid,
    RegionFingerprintManifest? manifest,
  }) async {
    // 1. Signature validity check
    if (!signatureValid) {
      return const VerificationResult(
        outcome: VerificationOutcome.invalidSignature,
        signatureValid: false,
        exactFileMatch: false,
        summary: 'Digital signature on record is invalid or tampered.',
        details: 'The record metadata could not be verified against the device public key.',
      );
    }

    // 2. If no image bytes were provided
    if (receivedBytes == null || receivedBytes.isEmpty) {
      return const VerificationResult(
        outcome: VerificationOutcome.recordAuthenticImageUnchecked,
        signatureValid: true,
        exactFileMatch: false,
        summary: 'Record is authentic, but no image was supplied for inspection.',
        details: 'The cryptographic signature on the record is valid. Supply the received photo to verify its pixels.',
      );
    }

    // 3. Layer A: Exact-file verification (SHA-256 over raw file bytes)
    final receivedSha256 = crypto.sha256.convert(receivedBytes).toString();
    final isExactMatch = (receivedSha256.toLowerCase() == expectedMediaSha256.toLowerCase());

    if (isExactMatch) {
      return VerificationResult(
        outcome: VerificationOutcome.exactMatch,
        signatureValid: true,
        exactFileMatch: true,
        regionCheckPassed: true,
        matchingRegions: manifest?.regions.length ?? 0,
        totalRegions: manifest?.regions.length ?? 0,
        originalDimensions: manifest != null ? '${manifest.imageWidth}x${manifest.imageHeight}' : null,
        testedDimensions: manifest != null ? '${manifest.imageWidth}x${manifest.imageHeight}' : null,
        summary: 'Exact file match verified.',
        details: 'SHA-256 matches the signed original digest byte-for-byte. The photo is authentic and unaltered.',
      );
    }

    // 4. Layer B: Image region integrity analysis (exact file SHA mismatch)
    if (manifest == null) {
      return const VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: null,
        summary: 'File SHA-256 differs from original (Modification detected).',
        details: 'The file digest does not match the signed original. No region fingerprint data is available for localized cropping analysis.',
      );
    }

    if (!manifest.isWellFormed) {
      return const VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: null,
        summary: 'File differs from the original; region analysis unavailable.',
        details: 'The fingerprint data is unsupported or malformed, so region analysis is inconclusive. The file digest does not match the signed original.',
      );
    }

    img.Image? decoded;
    try {
      decoded = img.decodeImage(receivedBytes);
    } catch (_) {}

    if (decoded == null) {
      return VerificationResult(
        outcome: VerificationOutcome.unableToVerify,
        signatureValid: true,
        exactFileMatch: false,
        summary: 'Unable to decode received image.',
        details: 'The file bytes could not be decoded as a valid image format.',
      );
    }

    final origW = manifest.imageWidth;
    final origH = manifest.imageHeight;
    final testW = decoded.width;
    final testH = decoded.height;
    final origDimStr = '${origW}x$origH';
    final testDimStr = '${testW}x$testH';

    // Dimension mismatch indicates cropping or resizing
    if (origW != testW || origH != testH) {
      final smaller = testW < origW || testH < origH;
      return VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: false,
        originalDimensions: origDimStr,
        testedDimensions: testDimStr,
        summary: smaller
            ? 'Dimensions differ: possible cropping or downscaling.'
            : 'Dimensions differ: image was resized or altered.',
        details: 'Registered original: $origDimStr, received: $testDimStr. '
            'The image is not the registered original. This check cannot tell '
            'cropping from resizing, and does not align resized copies.',
      );
    }

    // Same dimensions: compare grid regions
    final rows = manifest.gridRows;
    final cols = manifest.gridCols;
    final total = rows * cols;
    var matches = 0;
    final regionMatches = <bool>[];

    for (var r = 0; r < rows; r++) {
      final y0 = (r * testH) ~/ rows;
      final y1 = ((r + 1) * testH) ~/ rows;
      final h = y1 - y0;

      for (var c = 0; c < cols; c++) {
        final x0 = (c * testW) ~/ cols;
        final x1 = ((c + 1) * testW) ~/ cols;
        final w = x1 - x0;

        final crop = img.copyCrop(decoded, x: x0, y: y0, width: w, height: h);
        final digest = crypto.sha256.convert(crop.toUint8List()).toString();

        final idx = r * cols + c;
        final expectedDigest = idx < manifest.regions.length ? manifest.regions[idx] : null;
        final matched = (expectedDigest != null && expectedDigest.toLowerCase() == digest.toLowerCase());
        if (matched) matches++;
        regionMatches.add(matched);
      }
    }

    if (matches == total) {
      // All regions matched, but whole-file SHA-256 didn't (e.g. EXIF/metadata modification)
      return VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: true,
        matchingRegions: matches,
        totalRegions: total,
        originalDimensions: origDimStr,
        testedDimensions: testDimStr,
        regionMatches: regionMatches,
        summary: 'File differs from the original, but all pixel regions match.',
        details: 'All $total region pixel digests match the signed original. The file is NOT byte-identical (metadata, container or re-encoding differs), so it is not an exact match. Subtle edits inside a region cannot be ruled out beyond what the grid hashes cover.',
      );
    }

    final modifiedCount = total - matches;
    return VerificationResult(
      outcome: VerificationOutcome.modificationDetected,
      signatureValid: true,
      exactFileMatch: false,
      regionCheckPassed: false,
      matchingRegions: matches,
      totalRegions: total,
      originalDimensions: origDimStr,
      testedDimensions: testDimStr,
      regionMatches: regionMatches,
      summary: 'Modification detected in $modifiedCount of $total regions.',
      details: '$modifiedCount of $total grid regions differ from the signed original. Pixel tampering or localized modification detected.',
    );
  }
}
