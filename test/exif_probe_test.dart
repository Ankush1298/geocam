import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// Forensic probe: does ui.instantiateImageCodec (used by PhotoProcessor.stamp)
// apply an EXIF Orientation=2 (mirror-horizontal) tag? Fixture pixels are
// physically left=RED / right=BLUE and NOT mirrored; only the EXIF tag differs.
Future<bool> leftIsRed(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final img = (await codec.getNextFrame()).image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final i = (2 * img.width + 2) * 4; // pixel (2,2)
  final r = data!.getUint8(i), b = data.getUint8(i + 2);
  return r > b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PROBE: does instantiateImageCodec apply EXIF Orientation=2?', () async {
    final normalLeftRed = await leftIsRed('test/fixtures/exif_normal.jpg');
    final mirrorLeftRed = await leftIsRed('test/fixtures/exif_mirror2.jpg');
    // ignore: avoid_print
    print('EXIF=1 (normal): leftIsRed=$normalLeftRed');
    // ignore: avoid_print
    print('EXIF=2 (mirror): leftIsRed=$mirrorLeftRed');
    // Normal must be red-on-left. If the codec honors EXIF=2, the mirror
    // fixture will come back blue-on-left (leftIsRed=false).
    expect(normalLeftRed, isTrue);
  });
}
