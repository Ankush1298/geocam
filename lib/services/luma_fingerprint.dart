import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Tolerant region fingerprint (algorithm `grid-luma-v2`).
///
/// The photo is converted to brightness (luma), normalised to at most
/// [maxSide] px on its long side, and cut into a rows x cols grid. Each tile is
/// described by a 64-bit pattern (is each of its 8x8 sub-blocks brighter than
/// the tile average), its average brightness and a "flat" flag. Tiles are
/// compared with a distance threshold, so resizing, recompression and
/// re-saving still match while content changes inside a tile usually do not.
///
/// Limits: small or low-contrast edits can pass, rotation is not corrected,
/// and a crop is only located when it lines up with the tile grid.
const lumaAlgorithm = 'grid-luma-v2';
const lumaTileRegex = r'^[0-9a-f]{16}[0-9a-f]{2}[01]$';

const maxSide = 1024;

/// Largest luma-v2 grid the app will build or analyse (real records are 8x8). The crop
/// search below costs about (rows*cols)^2 * 64 work per candidate size, so this keeps the
/// worst case near a million tile operations; a 64x64 grid would be roughly 250x that.
const maxLumaGrid = 16;

/// Locations of changed tiles are only reported when the unchanged tiles line up closely
/// with the original. Measured on synthetic photos: recompression/resizing and genuine local
/// edits leave a median of 0-2 differing pattern bits (75th percentile up to 6) across the
/// textured tiles, while shifted/zoomed copies show a median of 3-23 or a 75th percentile >= 7.
/// This is a presentation rule only; the matching thresholds above are unchanged.
const alignMaxMedianBits = 3; // confident only if median < 3
const alignMaxP75Bits = 7; // ... and 75th percentile < 7
const alignMinStructuredTiles = 8; // fewer non-flat tiles: not enough evidence either way
const maxHamming = 12; // of 64 bits
const maxMeanDiff = 16; // of 255
const _flatStdDev = 4.0;

class LumaMap {
  final int w;
  final int h;
  final Float64List integral; // (w+1)*(h+1) summed-area table of luma
  final int srcW; // size of the decoded image before normalising
  final int srcH;
  LumaMap(this.w, this.h, this.integral, this.srcW, this.srcH);

  double mean(int x0, int y0, int x1, int y1) {
    final s = w + 1;
    final sum = integral[y1 * s + x1] - integral[y0 * s + x1] - integral[y1 * s + x0] + integral[y0 * s + x0];
    return sum / ((x1 - x0) * (y1 - y0));
  }
}

class Tile {
  final int hi;
  final int lo;
  final int mean;
  final bool flat;
  const Tile(this.hi, this.lo, this.mean, this.flat);

  static Tile? parse(String s) {
    if (!RegExp(lumaTileRegex).hasMatch(s)) return null;
    return Tile(int.parse(s.substring(0, 8), radix: 16), int.parse(s.substring(8, 16), radix: 16),
        int.parse(s.substring(16, 18), radix: 16), s[18] == '1');
  }

  @override
  String toString() =>
      '${hi.toRadixString(16).padLeft(8, '0')}${lo.toRadixString(16).padLeft(8, '0')}'
      '${mean.toRadixString(16).padLeft(2, '0')}${flat ? 1 : 0}';
}

int tileDistance(Tile a, Tile b) => _popcount(a.hi ^ b.hi) + _popcount(a.lo ^ b.lo);

/// Whether the tiles that are not flat agree closely enough to trust per-tile locations.
bool alignmentIsReliable(List<Tile> original, List<Tile> received) {
  final d = <int>[];
  for (var i = 0; i < original.length && i < received.length; i++) {
    if (!original[i].flat) d.add(tileDistance(original[i], received[i]));
  }
  if (d.length < alignMinStructuredTiles) return false;
  d.sort();
  return d[d.length ~/ 2] < alignMaxMedianBits && d[(d.length * 3) ~/ 4] < alignMaxP75Bits;
}

int _popcount(int v) {
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}

bool tilesMatch(Tile a, Tile b) {
  if ((a.mean - b.mean).abs() > maxMeanDiff) return false;
  if (a.flat && b.flat) return true; // bits of flat tiles are noise
  return _popcount(a.hi ^ b.hi) + _popcount(a.lo ^ b.lo) <= maxHamming;
}

/// Decodes and normalises an image. Pure Dart; call from a background isolate.
LumaMap? buildLumaMap(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) return null;
  final srcW = image.width, srcH = image.height;
  final longSide = max(srcW, srcH);
  if (longSide > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  final w = image.width, h = image.height, s = w + 1;
  final integral = Float64List(s * (h + 1));
  for (var y = 0; y < h; y++) {
    var row = 0.0;
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      row += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      integral[(y + 1) * s + x + 1] = integral[y * s + x + 1] + row;
    }
  }
  return LumaMap(w, h, integral, srcW, srcH);
}

Tile tileAt(LumaMap m, int rows, int cols, int r, int c) {
  final x0 = (c * m.w) ~/ cols, x1 = ((c + 1) * m.w) ~/ cols;
  final y0 = (r * m.h) ~/ rows, y1 = ((r + 1) * m.h) ~/ rows;
  final tw = max(1, x1 - x0), th = max(1, y1 - y0);
  final means = List<double>.filled(64, 0);
  for (var i = 0; i < 8; i++) {
    final by0 = min(m.h - 1, y0 + (i * th) ~/ 8);
    final by1 = min(m.h, max(by0 + 1, y0 + ((i + 1) * th) ~/ 8));
    for (var j = 0; j < 8; j++) {
      final bx0 = min(m.w - 1, x0 + (j * tw) ~/ 8);
      final bx1 = min(m.w, max(bx0 + 1, x0 + ((j + 1) * tw) ~/ 8));
      means[i * 8 + j] = m.mean(bx0, by0, bx1, by1);
    }
  }
  final avg = means.reduce((a, b) => a + b) / 64;
  final variance = means.map((v) => (v - avg) * (v - avg)).reduce((a, b) => a + b) / 64;
  var hi = 0, lo = 0;
  for (var k = 0; k < 64; k++) {
    if (means[k] > avg) {
      if (k < 32) {
        hi |= 1 << (31 - k);
      } else {
        lo |= 1 << (63 - k);
      }
    }
  }
  return Tile(hi, lo, avg.round().clamp(0, 255), sqrt(variance) < _flatStdDev);
}

List<Tile> gridTiles(LumaMap m, int rows, int cols) =>
    [for (var r = 0; r < rows; r++) for (var c = 0; c < cols; c++) tileAt(m, rows, cols, r, c)];

/// Best tile-aligned sub-rectangle of the original that the received image matches.
class CropMatch {
  final int row0, col0, nRows, nCols;
  final double fraction;
  const CropMatch(this.row0, this.col0, this.nRows, this.nCols, this.fraction);
}

CropMatch? findAlignedCrop(List<Tile> orig, int rows, int cols, int origW, int origH, LumaMap recv) {
  if (rows > maxLumaGrid || cols > maxLumaGrid) return null; // defence in depth; callers also check
  final recvAspect = recv.w / recv.h;
  final tileAspect = (origW / cols) / (origH / rows);
  CropMatch? best;
  for (var nr = 1; nr <= rows; nr++) {
    for (var nc = 1; nc <= cols; nc++) {
      if (nr == rows && nc == cols) continue;
      if (nr * nc < 4) continue;
      if ((log(nc * tileAspect / nr / recvAspect)).abs() > 0.06) continue;
      final got = gridTiles(recv, nr, nc);
      for (var r0 = 0; r0 + nr <= rows; r0++) {
        for (var c0 = 0; c0 + nc <= cols; c0++) {
          var ok = 0, structured = 0;
          for (var i = 0; i < nr; i++) {
            for (var j = 0; j < nc; j++) {
              final o = orig[(r0 + i) * cols + c0 + j];
              if (tilesMatch(o, got[i * nc + j])) {
                ok++;
                if (!o.flat) structured++;
              }
            }
          }
          final frac = ok / (nr * nc);
          if (structured >= 2 && frac >= 0.85 && (best == null || frac * nr * nc > best.fraction * best.nRows * best.nCols)) {
            best = CropMatch(r0, c0, nr, nc, frac);
          }
        }
      }
    }
  }
  return best;
}
