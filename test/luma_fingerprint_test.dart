import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/services/fingerprint_service.dart';
import 'package:geocam/services/luma_fingerprint.dart';
import 'package:image/image.dart' as img;

// ---- deterministic synthetic fixtures (no photos, no network) -----------------

img.Image smooth(int w, int h, int seed) {
  final im = img.Image(width: w, height: h);
  final rnd = Random(seed);
  final blobs = List.generate(
      20, (_) => [rnd.nextDouble() * w, rnd.nextDouble() * h, 30 + rnd.nextDouble() * w / 6, rnd.nextDouble() * 120 - 60]);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 128 + 30 * sin(x / (w / 9)) * cos(y / (h / 9));
      for (final b in blobs) {
        final d2 = (x - b[0]) * (x - b[0]) + (y - b[1]) * (y - b[1]);
        v += b[3] * exp(-d2 / (2 * b[2] * b[2]));
      }
      v += (rnd.nextDouble() - .5) * 5;
      final c = v.clamp(0, 255).round();
      im.setPixel(x, y, img.ColorRgb8(c, (c * .92).round(), (c * .85).round()));
    }
  }
  return im;
}

/// Foliage/grass-like texture: multi-scale (1/f-style) value noise plus mild grain.
/// Pure per-pixel white noise is deliberately not used: it is not what photos look like,
/// and any block-brightness fingerprint is unstable under resampling for it.
img.Image texture(int w, int h, int seed) {
  final rnd = Random(seed);
  const cells = [64, 32, 16, 8, 4];
  final grids = [
    for (final c in cells) List.generate((h ~/ c + 2) * (w ~/ c + 2), (_) => rnd.nextDouble() * 2 - 1),
  ];
  double sample(int oi, double x, double y) {
    final c = cells[oi];
    final gw = w ~/ c + 2;
    final gx = x / c, gy = y / c;
    final x0 = gx.floor(), y0 = gy.floor();
    final fx = gx - x0, fy = gy - y0;
    double g(int xx, int yy) => grids[oi][yy * gw + xx];
    final top = g(x0, y0) * (1 - fx) + g(x0 + 1, y0) * fx;
    final bot = g(x0, y0 + 1) * (1 - fx) + g(x0 + 1, y0 + 1) * fx;
    return top * (1 - fy) + bot * fy;
  }
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 120.0;
      var amp = 45.0;
      for (var o = 0; o < cells.length; o++) {
        v += amp * sample(o, x.toDouble(), y.toDouble());
        amp *= .6;
      }
      v += (rnd.nextDouble() - .5) * 14;
      final c = v.clamp(0, 255).round();
      im.setPixel(x, y, img.ColorRgb8((c * .8).round(), c, (c * .6).round()));
    }
  }
  return im;
}

Uint8List jpg(img.Image i, [int q = 90]) => Uint8List.fromList(img.encodeJpg(i, quality: q));

typedef Orig = ({Uint8List bytes, String sha, RegionFingerprintManifest m});

Future<Orig> makeOriginal(img.Image i) async {
  final bytes = jpg(i, 95);
  return (
    bytes: bytes,
    sha: crypto.sha256.convert(bytes).toString(),
    m: (await FingerprintService.generate(bytes))!,
  );
}

Future<VerificationResult> check(Orig o, Uint8List received) => FingerprintService.verify(
    receivedBytes: received, expectedMediaSha256: o.sha, signatureValid: true, manifest: o.m);

img.Image decoded(Orig o) => img.decodeImage(o.bytes)!;

void paint(img.Image im, int x, int y, int w, int h, int delta) {
  final p = im.getPixel(x, y);
  final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
  final c = (lum + delta).clamp(0, 255);
  img.fillRect(im, x1: x, y1: y, x2: x + w, y2: y + h, color: img.ColorRgb8(c, c, c));
}

void main() {
  group('tile matching thresholds (maxMeanDiff 16, maxHamming 12 of 64)', () {
    test('thresholds are the documented values', () {
      expect(maxMeanDiff, 16);
      expect(maxHamming, 12);
      expect(maxSide, 1024);
    });

    test('Hamming distance 12 matches, 13 does not', () {
      const a = Tile(0, 0, 100, false);
      expect(tilesMatch(a, const Tile(0x00000fff, 0, 100, false)), isTrue); // 12 bits
      expect(tilesMatch(a, const Tile(0x00001fff, 0, 100, false)), isFalse); // 13 bits
      expect(tilesMatch(a, const Tile(0x000007ff, 0x00000001, 100, false)), isTrue); // 11 + 1 across both words
      expect(tilesMatch(a, const Tile(0x00000fff, 0x00000001, 100, false)), isFalse); // 13 across both words
    });

    test('brightness difference 16 matches, 17 does not', () {
      const a = Tile(0, 0, 100, false);
      expect(tilesMatch(a, const Tile(0, 0, 116, false)), isTrue);
      expect(tilesMatch(a, const Tile(0, 0, 117, false)), isFalse);
      expect(tilesMatch(a, const Tile(0, 0, 84, false)), isTrue);
      expect(tilesMatch(a, const Tile(0, 0, 83, false)), isFalse);
    });

    test('two flat tiles compare by brightness only; flat vs structured uses the bits', () {
      expect(tilesMatch(const Tile(0xffffffff, 0xffffffff, 90, true), const Tile(0, 0, 95, true)), isTrue);
      expect(tilesMatch(const Tile(0xffffffff, 0xffffffff, 90, true), const Tile(0, 0, 95, false)), isFalse);
    });

    test('tile strings round-trip and malformed ones are rejected', () {
      const t = Tile(0x0f0f0f0f, 0xf0f0f0f0, 0x7f, true);
      expect(t.toString(), '0f0f0f0ff0f0f0f07f1');
      expect(Tile.parse(t.toString())!.toString(), t.toString());
      for (final bad in ['', 'x' * 19, '0f0f0f0ff0f0f0f07f2', '0F0F0F0FF0F0F0F07F1', '0f0f0f0ff0f0f0f07f', '0f0f0f0ff0f0f0f07f10']) {
        expect(Tile.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('tile computation', () {
    test('left-dark / right-bright image gives the exact expected bit pattern', () {
      final im = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final c = x < 32 ? 40 : 200;
          im.setPixel(x, y, img.ColorRgb8(c, c, c));
        }
      }
      final m = buildLumaMap(Uint8List.fromList(img.encodePng(im)))!;
      final t = tileAt(m, 1, 1, 0, 0);
      expect(t.hi, 0x0f0f0f0f); // each of 8 rows: columns 4..7 brighter than average
      expect(t.lo, 0x0f0f0f0f);
      expect((t.mean - 120).abs(), lessThanOrEqualTo(1));
      expect(t.flat, isFalse);
    });

    test('tile order is row-major', () async {
      final im = img.Image(width: 64, height: 64);
      img.fill(im, color: img.ColorRgb8(20, 20, 20));
      img.fillRect(im, x1: 32, y1: 0, x2: 63, y2: 31, color: img.ColorRgb8(230, 230, 230)); // top-right quadrant
      final m = (await FingerprintService.generate(Uint8List.fromList(img.encodePng(im)), gridRows: 2, gridCols: 2))!;
      final means = m.regions.map((r) => Tile.parse(r)!.mean).toList();
      expect(means[1], greaterThan(200)); // row 0, col 1
      expect(means[0], lessThan(40));
      expect(means[2], lessThan(40));
      expect(means[3], lessThan(40));
    });

    test('deterministic for the same input', () async {
      final bytes = Uint8List.fromList(img.encodePng(smooth(200, 150, 1)));
      final a = await FingerprintService.generate(bytes);
      final b = await FingerprintService.generate(bytes);
      expect(a!.toCanonicalJson(), b!.toCanonicalJson());
    });

    test('odd sizes, partial tiles and tiny images are handled without errors', () async {
      for (final size in [const [1, 1], const [7, 5], const [8, 8], const [9, 9], const [16, 16], const [101, 77], const [333, 17]]) {
        final bytes = Uint8List.fromList(img.encodePng(texture(size[0], size[1], 4)));
        final m = await FingerprintService.generate(bytes);
        expect(m, isNotNull, reason: '$size');
        expect(m!.regions.length, 64);
        expect(m.isWellFormed, isTrue, reason: '$size');
        expect(m.imageWidth, size[0]);
        expect(m.imageHeight, size[1]);
      }
    });

    test('garbage bytes cannot be fingerprinted', () async {
      expect(buildLumaMap(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(await FingerprintService.generate(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(await FingerprintService.generate(Uint8List(0)), isNull);
    });

    test('large images are normalised to at most 1024 px for hashing but report true size', () async {
      final bytes = Uint8List.fromList(img.encodePng(smooth(2100, 400, 2)));
      final m = (await FingerprintService.generate(bytes))!;
      expect(m.imageWidth, 2100);
      expect(m.imageHeight, 400);
    });
  });

  group('verification scenarios (640x480 synthetic photos)', () {
    late Orig smoothO, textureO;
    setUpAll(() async {
      smoothO = await makeOriginal(smooth(640, 480, 5));
      textureO = await makeOriginal(texture(640, 480, 5));
    });

    test('1. byte-identical file is an exact match', () async {
      final r = await check(smoothO, smoothO.bytes);
      expect(r.outcome, VerificationOutcome.exactMatch);
      expect(r.exactFileMatch, isTrue);
    });

    test('2. JPEG recompression at several qualities is consistent, never exact', () async {
      for (final o in [smoothO, textureO]) {
        for (final q in [90, 70, 50, 30]) {
          final r = await check(o, jpg(decoded(o), q));
          expect(r.outcome, VerificationOutcome.reencodedContentConsistent, reason: 'q$q');
          expect(r.exactFileMatch, isFalse);
          expect(r.isAuthentic, isFalse);
          expect(r.summary.toLowerCase(), isNot(contains('authentic')));
          expect(r.details.toLowerCase(), contains('not proof'));
        }
      }
    });

    test('3. downscaling keeps framing and is consistent', () async {
      for (final o in [smoothO, textureO]) {
        for (final w in [480, 320, 256]) {
          final r = await check(o, jpg(img.copyResize(decoded(o), width: w), 80));
          expect(r.outcome, VerificationOutcome.reencodedContentConsistent,
              reason: '${w}px ${o == smoothO ? 'smooth' : 'texture'}: ${r.summary} ${r.matchingRegions}/64');
          expect(r.testedDimensions, startsWith('${w}x'));
        }
      }
    });

    test('4/5. large high-contrast edits are flagged on smooth and textured photos', () async {
      for (final o in [smoothO, textureO]) {
        for (final delta in [-120, 120]) {
          final e = decoded(o);
          paint(e, 160, 120, 80, 60, delta); // exactly one tile (80x60) of an 8x8 grid
          final r = await check(o, jpg(e));
          expect(r.outcome, VerificationOutcome.modificationDetected, reason: 'delta $delta');
          expect(r.regionMatches![0], isTrue); // far corner untouched
        }
      }
    });

    test('4/5. bright-on-bright and dark-on-dark: large patches flagged, results never authentic', () async {
      final e = decoded(smoothO);
      final p = e.getPixel(300, 300);
      final bright = p.r > 150;
      paint(e, 240, 180, 160, 120, bright ? 60 : -60);
      final r = await check(smoothO, jpg(e));
      expect(r.isAuthentic, isFalse);
      expect(r.exactFileMatch, isFalse);
    });

    test('6/7/8. small, low-contrast and text edits are never reported as authentic', () async {
      final e = decoded(smoothO);
      paint(e, 100, 100, 20, 15, 15); // tiny, low contrast
      img.drawString(e, '1234', font: img.arial14, x: 300, y: 300, color: img.ColorRgb8(255, 255, 255));
      final r = await check(smoothO, jpg(e));
      expect(r.isAuthentic, isFalse);
      expect(r.exactFileMatch, isFalse);
      // Known limitation: such edits may well be reported as "content consistent"; the
      // wording must therefore never promise the image is unedited.
      if (r.outcome == VerificationOutcome.reencodedContentConsistent) {
        expect(r.details.toLowerCase(), contains('small or low-contrast edits'));
      }
    });

    test('9. edits grow more detectable with size (high contrast, smooth photo)', () async {
      final detected = <int>[];
      for (final side in [8, 20, 40, 80, 160]) {
        final e = decoded(smoothO);
        paint(e, 250, 200, side, side * 3 ~/ 4, 120);
        final r = await check(smoothO, jpg(e));
        if (r.outcome == VerificationOutcome.modificationDetected) detected.add(side);
      }
      expect(detected, contains(160));
      // Once an edit size is detected, every larger size is as well.
      for (var i = 1; i < detected.length; i++) {
        expect(detected[i], greaterThan(detected[i - 1]));
      }
      final tiny = decoded(smoothO);
      paint(tiny, 250, 200, 8, 6, 120);
      expect((await check(smoothO, jpg(tiny))).outcome, VerificationOutcome.reencodedContentConsistent,
          reason: '8x6 px edits are far below the grid resolution (documented limitation)');
    });

    test('10. tile-aligned crop is located', () async {
      final c = img.copyCrop(decoded(smoothO), x: 160, y: 0, width: 480, height: 480);
      final r = await check(smoothO, jpg(c));
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.summary, contains('columns 3-8'));
      expect(r.summary, contains('rows 1-8'));
    });

    test('11. unaligned crop is flagged without inventing a location', () async {
      final c = img.copyCrop(decoded(smoothO), x: 23, y: 11, width: 400, height: 410);
      final r = await check(smoothO, jpg(c));
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.summary.toLowerCase(), isNot(contains('columns')));
      expect(r.regionMatches, isNull);
    });

    test('12. rotated images are flagged and show no edit locations', () async {
      for (final angle in [90, 180, 270]) {
        final r = await check(smoothO, jpg(img.copyRotate(decoded(smoothO), angle: angle)));
        expect(r.outcome, VerificationOutcome.modificationDetected, reason: '$angle');
        expect(r.regionMatches, isNull, reason: 'no per-tile claims for rotation ($angle)');
        expect(r.isAuthentic, isFalse);
      }
    });

    test('13. different aspect ratio is reported as different framing', () async {
      final stretched = img.copyResize(decoded(smoothO), width: 640, height: 360, interpolation: img.Interpolation.average);
      final r = await check(smoothO, jpg(stretched));
      expect(r.outcome, VerificationOutcome.modificationDetected);
      expect(r.regionMatches, isNull);
    });

    test('14. near-minimum sizes: tiny image survives recompression check without crashing', () async {
      final o = await makeOriginal(texture(16, 16, 9));
      final r = await check(o, jpg(texture(16, 16, 9), 60));
      expect(r.isAuthentic, isFalse);
      final same = await check(o, o.bytes);
      expect(same.outcome, VerificationOutcome.exactMatch);
    });

    test('15. malformed input and metadata fail conservatively', () async {
      final garbage = Uint8List.fromList(List.generate(64, (i) => i));
      expect((await check(smoothO, garbage)).outcome, VerificationOutcome.unableToVerify);

      final noManifest = await FingerprintService.verify(
          receivedBytes: jpg(decoded(smoothO), 50), expectedMediaSha256: smoothO.sha, signatureValid: true, manifest: null);
      expect(noManifest.outcome, VerificationOutcome.modificationDetected);
      expect(noManifest.regionCheckPassed, isNull);

      final badTiles = RegionFingerprintManifest(imageWidth: 640, imageHeight: 480, regions: List.filled(64, 'nope'));
      final r1 = await FingerprintService.verify(
          receivedBytes: jpg(decoded(smoothO), 50), expectedMediaSha256: smoothO.sha, signatureValid: true, manifest: badTiles);
      expect(r1.isAuthentic, isFalse);
      expect(r1.regionCheckPassed, isNull);

      final unknown = RegionFingerprintManifest(
          algorithm: 'mystery-v9', imageWidth: 640, imageHeight: 480, regions: smoothO.m.regions);
      expect(unknown.isWellFormed, isFalse);

      final tooBig = RegionFingerprintManifest(imageWidth: 640, imageHeight: 480, gridRows: 65, gridCols: 65, regions: []);
      expect(tooBig.isWellFormed, isFalse);
      final wrongCount = RegionFingerprintManifest(imageWidth: 640, imageHeight: 480, regions: smoothO.m.regions.take(63).toList());
      expect(wrongCount.isWellFormed, isFalse);
    });

    test('invalid signature always wins', () async {
      final r = await FingerprintService.verify(
          receivedBytes: smoothO.bytes, expectedMediaSha256: smoothO.sha, signatureValid: false, manifest: smoothO.m);
      expect(r.outcome, VerificationOutcome.invalidSignature);
    });

    test('legacy grid-sha256-v1 manifests still verify exact copies and flag edits', () async {
      final legacy = await FingerprintService.generate(smoothO.bytes,
          gridRows: 4, gridCols: 4, algorithm: RegionFingerprintManifest.legacyAlgorithm);
      expect(legacy!.fpVersion, 1);
      expect(legacy.isWellFormed, isTrue);
      final ok = await FingerprintService.verify(
          receivedBytes: smoothO.bytes, expectedMediaSha256: smoothO.sha, signatureValid: true, manifest: legacy);
      expect(ok.outcome, VerificationOutcome.exactMatch);
      final e = decoded(smoothO);
      paint(e, 10, 10, 30, 30, 100);
      final bad = await FingerprintService.verify(
          receivedBytes: jpg(e), expectedMediaSha256: smoothO.sha, signatureValid: true, manifest: legacy);
      expect(bad.outcome, VerificationOutcome.modificationDetected);
    });
  });

  group('GPS clock offset inside the signed manifest', () {
    test('manifest carries the offset in its hashed canonical JSON', () async {
      final bytes = Uint8List.fromList(img.encodePng(texture(64, 64, 1)));
      final m = (await FingerprintService.generate(bytes, gridRows: 2, gridCols: 2, gpsClockOffsetMs: 4200))!;
      final json = m.toCanonicalJson();
      expect(json, contains('"gpsClockOffsetMs":4200,'));
      expect(json.indexOf('"fpVersion"'), lessThan(json.indexOf('"gpsClockOffsetMs"')));
      expect(json.indexOf('"gpsClockOffsetMs"'), lessThan(json.indexOf('"gridCols"')));
      expect(RegionFingerprintManifest.parseJson(json)!.gpsClockOffsetMs, 4200);
      final without = (await FingerprintService.generate(bytes, gridRows: 2, gridCols: 2))!;
      expect(without.toCanonicalJson(), isNot(contains('gpsClockOffsetMs')));
      expect(without.sha256Digest, isNot(m.sha256Digest)); // the offset is bound by the signed hash
    });

    test('absurd offsets make a manifest malformed', () {
      final m = RegionFingerprintManifest(
          imageWidth: 8, imageHeight: 8, gridRows: 1, gridCols: 1, regions: ['0' * 18 + '0'], gpsClockOffsetMs: 1 << 50);
      expect(m.isWellFormed, isFalse);
    });
  });

  group('Dart <-> Python golden manifest', () {
    img.Image goldenImage() {
      final im = img.Image(width: 96, height: 72);
      for (var y = 0; y < 72; y++) {
        for (var x = 0; x < 96; x++) {
          final c = ((x * 7 + y * 13) % 200) + 20;
          im.setPixel(x, y, img.ColorRgb8(c, (c * 3) % 256, (x * y) % 256));
        }
      }
      return im;
    }

    test('lossless fixture produces exactly the committed manifest (read-only)', () async {
      final bytes = Uint8List.fromList(img.encodePng(goldenImage()));
      final m = (await FingerprintService.generate(bytes, gridRows: 4, gridCols: 4, gpsClockOffsetMs: 4200))!;
      final fixture = File('tests/fixtures/manifest_v2_golden.json');
      if (!fixture.existsSync()) {
        fail('Missing fixture tests/fixtures/manifest_v2_golden.json (tests never create it). '
            'Run the tests from the project root. If it was deleted, restore it from git; to regenerate it '
            'deliberately, save this exact text there:\n${m.toCanonicalJson()}');
      }
      final expected = fixture.readAsStringSync();
      expect(m.toCanonicalJson(), expected, reason: 'generator output no longer matches the committed fixture');
      expect(m.sha256Digest, crypto.sha256.convert(utf8.encode(expected)).toString());
    });
  });

  group('alignment uncertainty (shifted / zoomed copies) - presentation rule', () {
    late Orig tex, smo;
    setUpAll(() async {
      tex = await makeOriginal(texture(640, 480, 5));
      smo = await makeOriginal(smooth(640, 480, 5));
    });

    Future<VerificationResult> run(Orig o, img.Image im) => check(o, jpg(im));

    void expectNoLocations(VerificationResult r, String why) {
      expect(r.outcome, VerificationOutcome.modificationDetected, reason: why);
      expect(r.regionMatches, isNull, reason: '$why must not claim specific regions');
      expect(r.summary, contains('cannot be reliably located'), reason: why);
      expect(r.isAuthentic, isFalse);
    }

    test('small same-aspect crops that shift the content do not get edit locations', () async {
      // Measured on this exact fixture: 9 of 64 tiles differ, so tile flags alone would look like edits.
      final c = img.copyCrop(decoded(tex), x: 8, y: 6, width: 624, height: 468);
      expectNoLocations(await run(tex, c), '8px same-aspect crop');
      final bigger = img.copyCrop(decoded(tex), x: 16, y: 12, width: 608, height: 456);
      expectNoLocations(await run(tex, bigger), '16px same-aspect crop (half the tiles differ)');
    });

    test('zooms and translations do not get edit locations', () async {
      final z = img.copyResize(img.copyCrop(decoded(tex), x: 10, y: 7, width: 620, height: 466), width: 640, height: 480);
      expectNoLocations(await run(tex, z), '3% zoom');
      final z2 = img.copyResize(img.copyCrop(decoded(smo), x: 32, y: 24, width: 576, height: 432), width: 640, height: 480);
      expectNoLocations(await run(smo, z2), '10% zoom on a smooth photo');
      expectNoLocations(await run(tex, img.copyCrop(decoded(tex), x: 10, y: 0, width: 630, height: 480)), '10px translation');
    });

    test('very small shifts are within tolerance and reported as consistent, never exact', () async {
      final r = await run(tex, img.copyCrop(decoded(tex), x: 2, y: 1, width: 636, height: 478));
      expect(r.outcome, VerificationOutcome.reencodedContentConsistent);
      expect(r.exactFileMatch, isFalse);
    });

    test('crops next to a tile boundary are located or reported conservatively, never as edit tiles', () async {
      for (final x in [78, 80, 82]) {
        final r = await run(smo, img.copyCrop(decoded(smo), x: x, y: 0, width: 640 - x, height: 480));
        expect(r.outcome, VerificationOutcome.modificationDetected, reason: 'x=$x');
        expect(r.regionMatches, isNull, reason: 'x=$x');
      }
    });

    test('ordinary same-framing localized edits keep their precise locations', () async {
      for (final o in [tex, smo]) {
        final e = decoded(o);
        paint(e, 200, 150, 160, 120, 120);
        final r = await run(o, e);
        expect(r.outcome, VerificationOutcome.modificationDetected);
        expect(r.regionMatches, isNotNull, reason: 'aligned comparison with a local edit');
        expect(r.regionMatches!.where((m) => !m).length, inInclusiveRange(1, 20));
        expect(r.regionMatches![0], isTrue);
      }
    });

    test('recompressed and resized copies with the same framing stay consistent', () async {
      for (final o in [tex, smo]) {
        expect((await run(o, decoded(o))).outcome, VerificationOutcome.reencodedContentConsistent);
        final small = img.copyResize(decoded(o), width: 480);
        expect((await check(o, jpg(small, 80))).outcome, VerificationOutcome.reencodedContentConsistent);
      }
    });

    test('rotation and a different aspect ratio never produce locations', () async {
      expectNoLocations(await run(smo, img.copyRotate(decoded(smo), angle: 180)), '180 degrees');
      final r = await run(smo, img.copyResize(decoded(smo), width: 640, height: 360, interpolation: img.Interpolation.average));
      expect(r.regionMatches, isNull);
    });

    test('alignment rule: too little texture is not evidence of alignment', () {
      final flat = List.generate(64, (_) => const Tile(0, 0, 128, true));
      expect(alignmentIsReliable(flat, flat), isFalse);
      final good = List.generate(64, (_) => const Tile(0xffff, 0, 128, false));
      expect(alignmentIsReliable(good, good), isTrue);
      final shifted = List.generate(64, (_) => const Tile(0xffff0000, 0, 128, false)); // 32 bits apart
      expect(alignmentIsReliable(good, shifted), isFalse);
    });
  });

  group('computation bound (max luma grid 16x16)', () {
    test('constants', () => expect(maxLumaGrid, 16));

    test('boundary: 16x16 can be generated, 17 cannot', () async {
      final bytes = Uint8List.fromList(img.encodePng(texture(300, 300, 3)));
      final ok = await FingerprintService.generate(bytes, gridRows: 16, gridCols: 16);
      expect(ok, isNotNull);
      expect(ok!.regions.length, 256);
      expect(ok.isWellFormed, isTrue);
      expect(await FingerprintService.generate(bytes, gridRows: 17, gridCols: 17), isNull);
      expect(await FingerprintService.generate(bytes, gridRows: 16, gridCols: 17), isNull);
      expect(await FingerprintService.generate(bytes, gridRows: 0, gridCols: 8), isNull);
    });

    test('oversized luma manifests fail safely and quickly instead of searching', () async {
      final tile = Tile(0, 0, 100, false).toString();
      final huge = RegionFingerprintManifest(
          imageWidth: 640, imageHeight: 480, gridRows: 64, gridCols: 64, regions: List.filled(4096, tile));
      expect(huge.isWellFormed, isFalse);
      final just = RegionFingerprintManifest(
          imageWidth: 640, imageHeight: 480, gridRows: 17, gridCols: 17, regions: List.filled(289, tile));
      expect(just.isWellFormed, isFalse);
      final bytes = jpg(smooth(320, 240, 1));
      final sw = Stopwatch()..start();
      final r = await FingerprintService.verify(
          receivedBytes: bytes, expectedMediaSha256: 'f' * 64, signatureValid: true, manifest: huge);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(r.isAuthentic, isFalse);
      expect(r.regionCheckPassed, isNull);
      expect(r.details, contains('up to 16x16'));
      // defence in depth: the search itself refuses oversized grids
      final m = buildLumaMap(bytes)!;
      expect(findAlignedCrop(List.filled(4096, Tile.parse(tile)!), 64, 64, 640, 480, m), isNull);
    });

    test('worst supported case (16x16, hostile unaligned crop) finishes within a sane time', () async {
      final o = await makeOriginal(texture(640, 480, 8));
      final m16 = (await FingerprintService.generate(o.bytes, gridRows: 16, gridCols: 16))!;
      final cropped = img.copyCrop(decoded(o), x: 37, y: 11, width: 400, height: 300);
      final sw = Stopwatch()..start();
      final r = await FingerprintService.verify(
          receivedBytes: jpg(cropped), expectedMediaSha256: o.sha, signatureValid: true, manifest: m16);
      expect(r.isAuthentic, isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test('default grid is still 8x8', () {
      expect(RegionFingerprintManifest.defaultGridRows, 8);
      expect(RegionFingerprintManifest.defaultGridCols, 8);
    });
  });
}
