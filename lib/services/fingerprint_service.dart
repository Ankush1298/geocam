import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

import 'luma_fingerprint.dart';

/// Outcome classifications required by the GeoCam privacy-first specification.
enum VerificationOutcome {
  exactMatch,
  modificationDetected,
  reencodedContentConsistent,
  recordAuthenticImageUnchecked,
  unableToVerify,
  invalidSignature;

  String get label {
    switch (this) {
      case VerificationOutcome.exactMatch:
        return 'EXACT MATCH';
      case VerificationOutcome.modificationDetected:
        return 'MODIFICATION DETECTED';
      case VerificationOutcome.reencodedContentConsistent:
        return 'FILE CHANGED, CONTENT CONSISTENT';
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
  static const legacyAlgorithm = 'grid-sha256-v1';
  static const defaultAlgorithm = lumaAlgorithm;

  final int fpVersion;
  final String algorithm;
  final int imageWidth;
  final int imageHeight;
  final int gridRows;
  final int gridCols;
  final List<String> regions;

  /// Phone clock minus GPS satellite time at capture, in ms (positive = phone ahead).
  /// Optional; signed because it lives inside the hashed manifest. Null = no GPS time.
  final int? gpsClockOffsetMs;

  const RegionFingerprintManifest({
    this.fpVersion = 2,
    this.algorithm = defaultAlgorithm,
    required this.imageWidth,
    required this.imageHeight,
    this.gridRows = defaultGridRows,
    this.gridCols = defaultGridCols,
    required this.regions,
    this.gpsClockOffsetMs,
  });

  /// Canonical JSON representation with alphabetically sorted keys.
  /// Exactly matches the server-side canonicalization in app.py.
  String toCanonicalJson() {
    final buffer = StringBuffer();
    buffer.write('{');
    buffer.write('"algorithm":${jsonEncode(algorithm)},');
    buffer.write('"fpVersion":$fpVersion,');
    if (gpsClockOffsetMs != null) buffer.write('"gpsClockOffsetMs":$gpsClockOffsetMs,');
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

  int get _maxGrid => algorithm == lumaAlgorithm ? maxLumaGrid : 64;

  /// Bounds check so a hostile manifest cannot cause huge loops.
  bool get isWellFormed =>
      (algorithm == defaultAlgorithm || algorithm == legacyAlgorithm) &&
      gridRows > 0 && gridRows <= _maxGrid && gridCols > 0 && gridCols <= _maxGrid &&
      regions.length == gridRows * gridCols &&
      imageWidth > 0 && imageHeight > 0 && imageWidth <= 100000 && imageHeight <= 100000 &&
      (gpsClockOffsetMs == null || gpsClockOffsetMs!.abs() <= 366 * 24 * 3600 * 1000) &&
      (algorithm != lumaAlgorithm || regions.every((t) => Tile.parse(t) != null));

  /// SHA-256 of the canonical JSON string.
  String get sha256Digest =>
      crypto.sha256.convert(utf8.encode(toCanonicalJson())).toString();

  factory RegionFingerprintManifest.fromJson(Map<String, dynamic> json) {
    return RegionFingerprintManifest(
      fpVersion: (json['fpVersion'] as num?)?.toInt() ?? 1,
      algorithm: (json['algorithm'] as String?) ?? legacyAlgorithm,
      imageWidth: (json['imageWidth'] as num).toInt(),
      imageHeight: (json['imageHeight'] as num).toInt(),
      gridRows: (json['gridRows'] as num?)?.toInt() ?? defaultGridRows,
      gridCols: (json['gridCols'] as num?)?.toInt() ?? defaultGridCols,
      regions: (json['regions'] as List).map((e) => e.toString()).toList(),
      gpsClockOffsetMs: (json['gpsClockOffsetMs'] is int) ? json['gpsClockOffsetMs'] as int : null,
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

/// Region digests over the decoded pixel buffer (`image` package, no EXIF
/// rotation applied; the same decode is used when generating and verifying).
/// Runs in a background isolate because decoding a full photo is slow.
({int width, int height, List<String> digests})? _grid(Uint8List bytes, int rows, int cols) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  final digests = <String>[];
  for (var r = 0; r < rows; r++) {
    final y0 = (r * image.height) ~/ rows;
    final y1 = ((r + 1) * image.height) ~/ rows;
    for (var c = 0; c < cols; c++) {
      final x0 = (c * image.width) ~/ cols;
      final x1 = ((c + 1) * image.width) ~/ cols;
      final crop = img.copyCrop(image, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
      digests.add(crypto.sha256.convert(crop.toUint8List()).toString());
    }
  }
  return (width: image.width, height: image.height, digests: digests);
}

/// Service to generate and verify image region fingerprints (Layer B).
class FingerprintService {
  /// Compute region fingerprints over image bytes.
  static Future<RegionFingerprintManifest?> generate(
    Uint8List imageBytes, {
    int gridRows = RegionFingerprintManifest.defaultGridRows,
    int gridCols = RegionFingerprintManifest.defaultGridCols,
    String algorithm = RegionFingerprintManifest.defaultAlgorithm,
    int? gpsClockOffsetMs,
  }) async {
    try {
      if (algorithm == lumaAlgorithm) {
        if (gridRows < 1 || gridCols < 1 || gridRows > maxLumaGrid || gridCols > maxLumaGrid) return null;
        final r = await Isolate.run(() {
          final m = buildLumaMap(imageBytes);
          if (m == null) return null;
          return (w: m.srcW, h: m.srcH, tiles: gridTiles(m, gridRows, gridCols).map((t) => t.toString()).toList());
        });
        if (r == null) return null;
        return RegionFingerprintManifest(
          fpVersion: 2,
          algorithm: lumaAlgorithm,
          imageWidth: r.w,
          imageHeight: r.h,
          gridRows: gridRows,
          gridCols: gridCols,
          regions: r.tiles,
          gpsClockOffsetMs: gpsClockOffsetMs,
        );
      }
      final grid = await Isolate.run(() => _grid(imageBytes, gridRows, gridCols));
      if (grid == null) return null;
      return RegionFingerprintManifest(
        fpVersion: 1,
        algorithm: RegionFingerprintManifest.legacyAlgorithm,
        imageWidth: grid.width,
        imageHeight: grid.height,
        gridRows: gridRows,
        gridCols: gridCols,
        regions: grid.digests,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<VerificationResult> _verifyLuma(Uint8List bytes, RegionFingerprintManifest manifest) async {
    final rows = manifest.gridRows, cols = manifest.gridCols;
    final origDim = '${manifest.imageWidth}x${manifest.imageHeight}';
    final expected = [for (final t in manifest.regions) Tile.parse(t)!];
    final r = await Isolate.run(() {
      final m = buildLumaMap(bytes);
      if (m == null) return null;
      final sameFraming = (log((m.srcW / m.srcH) / (manifest.imageWidth / manifest.imageHeight))).abs() <= 0.015;
      return (
        w: m.srcW,
        h: m.srcH,
        sameFraming: sameFraming,
        tiles: sameFraming ? gridTiles(m, rows, cols) : <Tile>[],
        crop: sameFraming ? null : findAlignedCrop(expected, rows, cols, manifest.imageWidth, manifest.imageHeight, m),
      );
    });
    if (r == null) {
      return const VerificationResult(
        outcome: VerificationOutcome.unableToVerify,
        signatureValid: true,
        exactFileMatch: false,
        summary: 'Unable to decode received image.',
        details: 'The file bytes could not be decoded as a valid image format.',
      );
    }
    final testDim = '${r.w}x${r.h}';
    if (!r.sameFraming) {
      final c = r.crop;
      return VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: false,
        originalDimensions: origDim,
        testedDimensions: testDim,
        summary: c != null
            ? 'Cropped: matches columns ${c.col0 + 1}-${c.col0 + c.nCols} and rows ${c.row0 + 1}-${c.row0 + c.nRows} of the original.'
            : 'Framing differs or content changed; specific regions cannot be reliably located.',
        details: 'The shape of the received image ($testDim) differs from the registered original ($origDim). '
            '${c != null ? "About ${(c.fraction * 100).round()}% of its tiles match that part of the ${cols}x$rows grid. " : "It could not be matched to a part of the original grid (crops are only located when they follow the grid). "}'
            'This is not the registered original.',
      );
    }
    final total = rows * cols;
    final flags = [for (var i = 0; i < total; i++) tilesMatch(expected[i], r.tiles[i])];
    final matches = flags.where((f) => f).length;
    final resized = r.w != manifest.imageWidth || r.h != manifest.imageHeight;
    if (matches == total) {
      return VerificationResult(
        outcome: VerificationOutcome.reencodedContentConsistent,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: true,
        matchingRegions: matches,
        totalRegions: total,
        originalDimensions: origDim,
        testedDimensions: testDim,
        regionMatches: flags,
        summary: 'File is not the original, but its content is consistent with it.',
        details: 'The bytes differ from the signed original (${resized ? "resized, " : ""}recompressed or re-saved copies do this, e.g. via messaging apps). '
            'All $total tiles match within tolerance. Small or low-contrast edits inside a tile can still go unnoticed, so this is not proof the image is unedited.',
      );
    }
    final aligned = alignmentIsReliable(expected, r.tiles);
    if (matches * 2 < total || !aligned) {
      // Most tiles differ, or the tiles that do match are not closely aligned: this may be a shifted,
      // zoomed or rotated copy, a different picture or heavy edits. Per-tile locations would be
      // unreliable, so none are reported.
      return VerificationResult(
        outcome: VerificationOutcome.modificationDetected,
        signatureValid: true,
        exactFileMatch: false,
        regionCheckPassed: false,
        matchingRegions: matches,
        totalRegions: total,
        originalDimensions: origDim,
        testedDimensions: testDim,
        summary: 'Framing differs or content changed; specific regions cannot be reliably located.',
        details: '${total - matches} of $total tiles differ by more than the tolerance and the comparison is not closely aligned. That fits a shifted, zoomed or rotated copy, a different photo or heavy edits, so no edit locations are shown. This is not the registered original.',
      );
    }
    return VerificationResult(
      outcome: VerificationOutcome.modificationDetected,
      signatureValid: true,
      exactFileMatch: false,
      regionCheckPassed: false,
      matchingRegions: matches,
      totalRegions: total,
      originalDimensions: origDim,
      testedDimensions: testDim,
      regionMatches: flags,
      summary: 'Modification detected in ${total - matches} of $total regions.',
      details: '${total - matches} of $total tiles differ from the signed original by more than the tolerance for resizing or recompression. The rest line up closely, so these locations are indicative; a shifted or resized copy can also differ in places.',
    );
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
        details: 'SHA-256 matches the signed original digest byte-for-byte. The file is identical to the one that was signed.',
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
        details: 'The fingerprint data is unsupported, malformed or larger than this app analyses (luma grids up to ${maxLumaGrid}x$maxLumaGrid), so region analysis was skipped. The file digest does not match the signed original.',
      );
    }

    if (manifest.algorithm == lumaAlgorithm) {
      return _verifyLuma(receivedBytes, manifest);
    }

    ({int width, int height, List<String> digests})? grid;
    try {
      grid = await Isolate.run(() => _grid(receivedBytes, manifest.gridRows, manifest.gridCols));
    } catch (_) {}

    if (grid == null) {
      return const VerificationResult(
        outcome: VerificationOutcome.unableToVerify,
        signatureValid: true,
        exactFileMatch: false,
        summary: 'Unable to decode received image.',
        details: 'The file bytes could not be decoded as a valid image format.',
      );
    }

    final origW = manifest.imageWidth;
    final origH = manifest.imageHeight;
    final testW = grid.width;
    final testH = grid.height;
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

    for (var i = 0; i < total; i++) {
      final expected = i < manifest.regions.length ? manifest.regions[i] : null;
      final matched = expected != null && expected.toLowerCase() == grid.digests[i].toLowerCase();
      if (matched) matches++;
      regionMatches.add(matched);
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
