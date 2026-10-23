import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/services/exposure_meter.dart';

/// Builds a [LumaGrid] by painting rectangles (normalised) onto a background level.
LumaGrid scene(int w, int h, int background, List<(NormRect, int)> boxes) {
  final v = Uint8List(w * h)..fillRange(0, w * h, background);
  for (final (r, level) in boxes) {
    for (var y = (r.top * h).round(); y < (r.bottom * h).round(); y++) {
      for (var x = (r.left * w).round(); x < (r.right * w).round(); x++) {
        v[y * w + x] = level;
      }
    }
  }
  return LumaGrid(w, h, v);
}

void main() {
  group('FrameGeometry', () {
    test('rotation follows the ML Kit rule', () {
      expect(FrameGeometry.rotationFor(sensorOrientation: 90, deviceRotation: 0, front: false), 90);
      expect(FrameGeometry.rotationFor(sensorOrientation: 270, deviceRotation: 0, front: true), 270);
      expect(FrameGeometry.rotationFor(sensorOrientation: 90, deviceRotation: 90, front: false), 0);
      expect(FrameGeometry.rotationFor(sensorOrientation: 270, deviceRotation: 90, front: true), 0);
    });

    test('upright <-> buffer round-trips for every rotation', () {
      final rnd = Random(1);
      for (final rot in [0, 90, 180, 270]) {
        final g = FrameGeometry(rotation: rot);
        for (var i = 0; i < 20; i++) {
          final u = rnd.nextDouble(), v = rnd.nextDouble();
          final b = g.uprightToBuffer(u, v);
          final back = g.bufferToUpright(b.x, b.y);
          expect(back.x, closeTo(u, 1e-9));
          expect(back.y, closeTo(v, 1e-9));
        }
      }
    });

    test('a 90-degree back camera: the upright top-left is the buffer bottom-left', () {
      const g = FrameGeometry(rotation: 90);
      final b = g.uprightToBuffer(0, 0);
      expect(b.x, 0);
      expect(b.y, 1);
      expect(g.uprightSize(1920, 1080), (1080, 1920));
    });

    test('the front camera preview is mirrored left-right', () {
      const g = FrameGeometry(rotation: 0, mirrored: true);
      final u = g.displayToUpright(0.2, 0.3);
      expect(u.x, closeTo(0.8, 1e-9));
      expect(u.y, closeTo(0.3, 1e-9));
    });

    test('rectangles map back to the same display rectangle', () {
      for (final rot in [0, 90, 180, 270]) {
        for (final mirror in [false, true]) {
          final g = FrameGeometry(rotation: rot, mirrored: mirror);
          const r = NormRect(0.1, 0.2, 0.4, 0.7);
          final back = g.bufferRectToDisplay(g.displayRectToBuffer(r));
          expect(back.left, closeTo(r.left, 1e-9));
          expect(back.top, closeTo(r.top, 1e-9));
          expect(back.right, closeTo(r.right, 1e-9));
          expect(back.bottom, closeTo(r.bottom, 1e-9));
        }
      }
    });
  });

  group('RegionStats', () {
    test('mean, percentiles, clipped and dark fractions', () {
      final hist = List<int>.filled(256, 0);
      hist[10] = 10; // dark
      hist[128] = 80;
      hist[255] = 10; // clipped
      final s = RegionStats.fromHistogram(hist);
      expect(s.samples, 100);
      expect(s.mean, closeTo((10 * 10 + 128 * 80 + 255 * 10) / 100, 1e-9));
      expect(s.p05, 10);
      expect(s.p50, 128);
      expect(s.p95, 255);
      expect(s.clipped, closeTo(0.10, 1e-9));
      expect(s.dark, closeTo(0.10, 1e-9));
    });

    test('an empty region has no samples', () {
      expect(RegionStats.fromHistogram(List<int>.filled(256, 0)).samples, 0);
    });
  });

  group('LumaGrid.fromPlane', () {
    test('averages a plane with row padding down to the target size', () {
      const w = 640, h = 480, stride = 704; // padded rows
      final plane = Uint8List(stride * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          plane[y * stride + x] = x < w ~/ 2 ? 40 : 200;
        }
        for (var x = w; x < stride; x++) {
          plane[y * stride + x] = 255; // padding must be ignored
        }
      }
      final g = LumaGrid.fromPlane(plane, srcW: w, srcH: h, rowStride: stride, maxSide: 160);
      expect(g.width, 160);
      expect(g.height, 120);
      expect(g.at(10, 60), 40);
      expect(g.at(150, 60), 200);
      expect(g.stats().clipped, 0, reason: 'row padding is not image content');
    });

    test('honours a pixel stride of 2', () {
      const w = 100, h = 50;
      final plane = Uint8List(w * 2 * h);
      for (var i = 0; i < w * h; i++) {
        plane[i * 2] = 120;
        plane[i * 2 + 1] = 0;
      }
      final g = LumaGrid.fromPlane(plane, srcW: w, srcH: h, rowStride: w * 2, pixelStride: 2, maxSide: 50);
      expect(g.values.every((v) => v == 120), isTrue);
    });
  });

  group('screen estimate', () {
    test('finds a bright projection rectangle beside a darker presenter', () {
      final g = scene(160, 120, 60, [
        (const NormRect(0.45, 0.2, 0.95, 0.65), 252), // projected slide
        (const NormRect(0.15, 0.3, 0.25, 0.45), 90), // presenter's face
      ]);
      final s = g.findBrightScreen();
      expect(s, isNotNull);
      expect(s!.rect.left, closeTo(0.45, 0.02));
      expect(s.rect.right, closeTo(0.95, 0.02));
      expect(s.fill, greaterThan(0.9));
      expect(g.stats(s.rect).clipped, greaterThan(0.9));
    });

    test('no screen in an evenly lit room', () {
      expect(scene(160, 120, 110, const []).findBrightScreen(), isNull);
    });

    test('a thin bright strip (e.g. a ceiling light) is not a screen', () {
      final g = scene(160, 120, 60, [(const NormRect(0.1, 0.05, 0.9, 0.09), 250)]);
      expect(g.findBrightScreen(), isNull);
    });

    test('a bright area that is not rectangular is not a screen', () {
      // An L shape: fills well under 60% of its bounding box.
      final g = scene(160, 120, 60, [
        (const NormRect(0.1, 0.1, 0.2, 0.9), 240),
        (const NormRect(0.1, 0.8, 0.9, 0.9), 240),
      ]);
      expect(g.findBrightScreen(), isNull);
    });
  });

  group('slide mark', () {
    test('tapping a bright slide outlines the slide', () {
      final g = scene(160, 120, 60, [(const NormRect(0.5, 0.2, 0.9, 0.6), 230)]);
      final r = g.slideAround(0.7, 0.4);
      expect(r.left, closeTo(0.5, 0.02));
      expect(r.top, closeTo(0.2, 0.02));
      expect(r.right, closeTo(0.9, 0.02));
      expect(r.bottom, closeTo(0.6, 0.02));
    });

    test('tapping a dark slide uses a fixed box around the tap', () {
      final g = scene(160, 120, 30, const []);
      final r = g.slideAround(0.5, 0.5);
      expect(r.centerX, closeTo(0.5, 1e-9));
      expect(r.width, closeTo(0.3, 1e-9));
    });
  });

  test('stops between regions use linear light', () {
    expect(stopsBetween(128, 128), closeTo(0, 1e-9));
    // 2.2 * log2(255/128)
    expect(stopsBetween(128, 255), closeTo(2.2 * log(255 / 128) / ln2, 1e-6));
    expect(stopsBetween(200, 100), lessThan(0));
  });
}
