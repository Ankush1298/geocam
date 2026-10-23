import 'dart:math';

import 'package:flutter/foundation.dart';

/// Brightness measurements taken from the live preview's luma (Y) plane.
///
/// Values are 8-bit, gamma-encoded preview luma, not scene radiance. They describe what the camera
/// is currently recording, which is what decides whether a region is too dark or clipped. They are
/// estimates: the still photo uses the same exposure but different processing (noise reduction,
/// tone mapping), so it can differ slightly from the preview.

/// Luma at or above this is treated as clipped highlight.
const clipLuma = 250;

/// Luma at or below this is treated as crushed shadow.
const darkLuma = 20;

/// A rectangle in normalised (0..1) coordinates.
@immutable
class NormRect {
  final double left, top, right, bottom;
  const NormRect(this.left, this.top, this.right, this.bottom);

  factory NormRect.centered(double cx, double cy, double halfW, double halfH) => NormRect(
        (cx - halfW).clamp(0.0, 1.0),
        (cy - halfH).clamp(0.0, 1.0),
        (cx + halfW).clamp(0.0, 1.0),
        (cy + halfH).clamp(0.0, 1.0),
      );

  double get width => right - left;
  double get height => bottom - top;
  double get area => width * height;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  bool get isEmpty => width <= 0 || height <= 0;

  /// The middle part of the rectangle (e.g. the inside of a face box, without hair or background).
  NormRect inset(double keepFraction) {
    final dx = width * (1 - keepFraction) / 2, dy = height * (1 - keepFraction) / 2;
    return NormRect(left + dx, top + dy, right - dx, bottom - dy);
  }

  @override
  bool operator ==(Object other) =>
      other is NormRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;
  @override
  int get hashCode => Object.hash(left, top, right, bottom);
  @override
  String toString() =>
      'NormRect(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, ${right.toStringAsFixed(3)}, ${bottom.toStringAsFixed(3)})';
}

/// Maps between the preview as the user sees it, the upright image, and the raw camera buffer.
///
/// * Display space: the preview widget, 0..1 (what a tap gives). The front camera preview is a mirror image.
/// * Upright space: the image the right way up, not mirrored (what ML Kit reports faces in).
/// * Buffer space: the sensor buffer as delivered, before rotation (what the luma plane is in).
class FrameGeometry {
  /// Clockwise rotation (0, 90, 180, 270) that turns the buffer upright.
  final int rotation;
  final bool mirrored;
  const FrameGeometry({required this.rotation, this.mirrored = false});

  /// Rotation needed to turn an Android camera buffer upright (same rule as the ML Kit samples).
  /// [deviceRotation] is the device orientation in degrees (portrait up = 0).
  static int rotationFor({required int sensorOrientation, required int deviceRotation, required bool front}) =>
      front ? (sensorOrientation + deviceRotation) % 360 : (sensorOrientation - deviceRotation + 360) % 360;

  Point<double> displayToUpright(double x, double y) => Point(mirrored ? 1 - x : x, y);
  Point<double> uprightToDisplay(double u, double v) => Point(mirrored ? 1 - u : u, v);

  Point<double> uprightToBuffer(double u, double v) {
    switch (rotation) {
      case 90:
        return Point(v, 1 - u);
      case 180:
        return Point(1 - u, 1 - v);
      case 270:
        return Point(1 - v, u);
      default:
        return Point(u, v);
    }
  }

  Point<double> bufferToUpright(double x, double y) {
    switch (rotation) {
      case 90:
        return Point(1 - y, x);
      case 180:
        return Point(1 - x, 1 - y);
      case 270:
        return Point(y, 1 - x);
      default:
        return Point(x, y);
    }
  }

  NormRect _mapRect(NormRect r, Point<double> Function(double, double) f) {
    final a = f(r.left, r.top), b = f(r.right, r.bottom);
    return NormRect(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y));
  }

  NormRect uprightRectToBuffer(NormRect r) => _mapRect(r, uprightToBuffer);
  NormRect bufferRectToUpright(NormRect r) => _mapRect(r, bufferToUpright);
  NormRect displayRectToBuffer(NormRect r) =>
      _mapRect(r, (x, y) {
        final u = displayToUpright(x, y);
        return uprightToBuffer(u.x, u.y);
      });
  NormRect bufferRectToDisplay(NormRect r) =>
      _mapRect(r, (x, y) {
        final u = bufferToUpright(x, y);
        return uprightToDisplay(u.x, u.y);
      });

  /// Size of the upright image for a buffer of [w] x [h].
  (int, int) uprightSize(int w, int h) => rotation == 90 || rotation == 270 ? (h, w) : (w, h);
}

/// Brightness statistics of one region.
@immutable
class RegionStats {
  final double mean;
  final int p05;
  final int p50;
  final int p95;

  /// Fraction (0..1) of pixels at or above [clipLuma].
  final double clipped;

  /// Fraction (0..1) of pixels at or below [darkLuma].
  final double dark;
  final int samples;

  const RegionStats({
    required this.mean,
    required this.p05,
    required this.p50,
    required this.p95,
    required this.clipped,
    required this.dark,
    required this.samples,
  });

  static RegionStats fromHistogram(List<int> hist) {
    final n = hist.fold<int>(0, (a, b) => a + b);
    if (n == 0) {
      return const RegionStats(mean: 0, p05: 0, p50: 0, p95: 0, clipped: 0, dark: 0, samples: 0);
    }
    var sum = 0, clipped = 0, dark = 0;
    for (var v = 0; v < 256; v++) {
      sum += v * hist[v];
      if (v >= clipLuma) clipped += hist[v];
      if (v <= darkLuma) dark += hist[v];
    }
    int pct(double q) {
      final target = q * (n - 1);
      var acc = 0;
      for (var v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc > target) return v;
      }
      return 255;
    }

    return RegionStats(
      mean: sum / n,
      p05: pct(0.05),
      p50: pct(0.50),
      p95: pct(0.95),
      clipped: clipped / n,
      dark: dark / n,
      samples: n,
    );
  }
}

/// A downsampled copy of the preview's luma plane (buffer space).
class LumaGrid {
  final int width;
  final int height;
  final Uint8List values;
  LumaGrid(this.width, this.height, this.values) : assert(values.length == width * height);

  /// Averages [plane] (a Y plane of [srcW] x [srcH] with [rowStride] bytes per row and
  /// [pixelStride] bytes per sample) down to at most [maxSide] pixels on the long side.
  factory LumaGrid.fromPlane(
    Uint8List plane, {
    required int srcW,
    required int srcH,
    required int rowStride,
    int pixelStride = 1,
    int maxSide = 160,
  }) {
    final scale = max(1, (max(srcW, srcH) / maxSide).ceil());
    final w = max(1, srcW ~/ scale), h = max(1, srcH ~/ scale);
    final out = Uint8List(w * h);
    // Sample a 4x4 lattice inside each cell: enough to average out sensor noise at a fraction of
    // the cost of reading every pixel.
    final step = max(1, scale ~/ 4);
    for (var gy = 0; gy < h; gy++) {
      for (var gx = 0; gx < w; gx++) {
        var sum = 0, count = 0;
        final y0 = gy * scale, x0 = gx * scale;
        for (var dy = 0; dy < scale; dy += step) {
          final row = (y0 + dy) * rowStride;
          for (var dx = 0; dx < scale; dx += step) {
            final idx = row + (x0 + dx) * pixelStride;
            if (idx < plane.length) {
              sum += plane[idx];
              count++;
            }
          }
        }
        out[gy * w + gx] = count == 0 ? 0 : sum ~/ count;
      }
    }
    return LumaGrid(w, h, out);
  }

  int at(int x, int y) => values[y * width + x];

  List<int> histogram([NormRect? r]) {
    final hist = List<int>.filled(256, 0);
    final x0 = r == null ? 0 : (r.left * width).floor().clamp(0, width - 1);
    final y0 = r == null ? 0 : (r.top * height).floor().clamp(0, height - 1);
    final x1 = r == null ? width : (r.right * width).ceil().clamp(x0 + 1, width);
    final y1 = r == null ? height : (r.bottom * height).ceil().clamp(y0 + 1, height);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        hist[values[y * width + x]]++;
      }
    }
    return hist;
  }

  RegionStats stats([NormRect? r]) => RegionStats.fromHistogram(histogram(r));

  /// Estimated bright projection screen or display: the largest connected bright area that fills
  /// most of its bounding box. Returns null when nothing looks like a screen. This is a heuristic:
  /// a window or white wall can match, and a dark slide with light text usually will not.
  ScreenEstimate? findBrightScreen() {
    final global = stats();
    // Bright relative to the scene, but never below a level that could be a dim wall.
    final threshold = max(170, (global.p95 * 0.85).round());
    final n = width * height;
    final label = Int32List(n)..fillRange(0, n, -1);
    var bestArea = 0, bestX0 = 0, bestY0 = 0, bestX1 = 0, bestY1 = 0;
    final stack = <int>[];
    var comp = 0;
    for (var start = 0; start < n; start++) {
      if (label[start] != -1 || values[start] < threshold) continue;
      var area = 0, x0 = width, y0 = height, x1 = 0, y1 = 0;
      label[start] = comp;
      stack.add(start);
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final px = p % width, py = p ~/ width;
        area++;
        if (px < x0) x0 = px;
        if (px > x1) x1 = px;
        if (py < y0) y0 = py;
        if (py > y1) y1 = py;
        void visit(int q) {
          if (label[q] == -1 && values[q] >= threshold) {
            label[q] = comp;
            stack.add(q);
          }
        }

        if (px > 0) visit(p - 1);
        if (px < width - 1) visit(p + 1);
        if (py > 0) visit(p - width);
        if (py < height - 1) visit(p + width);
      }
      if (area > bestArea) {
        bestArea = area;
        bestX0 = x0;
        bestY0 = y0;
        bestX1 = x1;
        bestY1 = y1;
      }
      comp++;
    }
    if (bestArea == 0) return null;
    final bw = bestX1 - bestX0 + 1, bh = bestY1 - bestY0 + 1;
    final fill = bestArea / (bw * bh);
    final areaFraction = bestArea / n;
    final aspect = max(bw, bh) / min(bw, bh);
    if (areaFraction < 0.03 || areaFraction > 0.85 || fill < 0.6 || aspect > 2.6) return null;
    return ScreenEstimate(
      NormRect(bestX0 / width, bestY0 / height, (bestX1 + 1) / width, (bestY1 + 1) / height),
      fill: fill,
      areaFraction: areaFraction,
    );
  }

  /// Region of a slide the user tapped: the bright area around the tap if the tap is on a bright
  /// area, otherwise a fixed box around the tap (dark slides with light text).
  NormRect slideAround(double bx, double by) {
    final x = (bx * width).floor().clamp(0, width - 1), y = (by * height).floor().clamp(0, height - 1);
    final seed = at(x, y);
    final box = NormRect.centered(bx, by, 0.15, 0.15);
    if (seed < 150) return box;
    final threshold = max(140, seed - 50);
    final seen = Uint8List(width * height);
    final stack = <int>[y * width + x];
    seen[y * width + x] = 1;
    var x0 = x, y0 = y, x1 = x, y1 = y, area = 0;
    while (stack.isNotEmpty && area < width * height) {
      final p = stack.removeLast();
      final px = p % width, py = p ~/ width;
      area++;
      x0 = min(x0, px);
      x1 = max(x1, px);
      y0 = min(y0, py);
      y1 = max(y1, py);
      for (final q in [
        if (px > 0) p - 1,
        if (px < width - 1) p + 1,
        if (py > 0) p - width,
        if (py < height - 1) p + width,
      ]) {
        if (seen[q] == 0 && values[q] >= threshold) {
          seen[q] = 1;
          stack.add(q);
        }
      }
    }
    final r = NormRect(x0 / width, y0 / height, (x1 + 1) / width, (y1 + 1) / height);
    // A flood that leaked into most of the frame is not a slide outline.
    return r.area > 0.85 || r.area < 0.005 ? box : r;
  }
}

@immutable
class ScreenEstimate {
  final NormRect rect;
  final double fill;
  final double areaFraction;
  const ScreenEstimate(this.rect, {required this.fill, required this.areaFraction});
}

/// Approximate linear light of 8-bit gamma-encoded luma (sRGB-like gamma 2.2).
double linearLight(double luma) => pow((luma.clamp(0, 255)) / 255.0, 2.2).toDouble();

/// Estimated difference in stops between two regions' mean luma, as recorded at the current
/// exposure. When the brighter region is clipped the true difference is larger than this.
double stopsBetween(double darkerMean, double brighterMean) {
  final a = linearLight(max(darkerMean, 1)), b = linearLight(max(brighterMean, 1));
  return log(b / a) / ln2;
}
