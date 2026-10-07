import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/models/camera_frame.dart';
import 'package:geocam/models/stamp_settings.dart';
import 'package:geocam/services/photo_processor.dart';

/// Front-camera orientation regression.
///
/// The application must not add its own front-camera mirror transform. CameraX
/// owns capture orientation; PhotoProcessor must preserve the camera-provided
/// orientation rather than transforming it a second time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> leftRed(Uint8List bytes) async {
    final im = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
    final d = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final i = (4 * im.width + 4) * 4;
    return d.getUint8(i) > d.getUint8(i + 2);
  }

  Uint8List fx(String n) => File('test/fixtures/$n').readAsBytesSync();

  Future<Uint8List> run(Uint8List jpg, {required bool front, bool stamp = true}) =>
      PhotoProcessor().stamp(
        jpg: jpg, position: null, address: '', timestamp: DateTime.utc(2026),
        recordId: 'GC-TEST-FRONT',
        settings: StampSettings(
          showCoordinates: false, showAddress: false, showDateTime: false,
          showAccuracy: false, showQr: false, pixelEmbeddedStamps: stamp,
          cloudVerification: false,
        ),
        frame: CameraFrame.full, screenAspect: 1.0, isFrontCamera: front,
      );

  test('front-camera processing does not add a mirror', () async {
    final original = fx('exif_normal.jpg');
    expect(await leftRed(await run(original, front: true)), isTrue);
    expect(await leftRed(await run(original, front: true, stamp: false)), isTrue);
  });

  test('back camera is never flipped', () async {
    expect(await leftRed(await run(fx('exif_normal.jpg'), front: false)), isTrue);
  });

  test('processed output remains in the same orientation after re-decoding', () async {
    final out = await run(fx('exif_normal.jpg'), front: true);
    expect(await leftRed(out), isTrue);
  });
}
