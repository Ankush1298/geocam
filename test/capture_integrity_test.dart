import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/camera/camera_controller.dart';
import 'package:geocam/models/camera_tuning.dart';
import 'package:geocam/services/fingerprint_service.dart';
import 'package:geocam/services/hash_service.dart';
import 'package:geocam/services/history_store.dart';
import 'package:geocam/services/sync_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/camera_fakes.dart';

/// Capture pipeline regression with the new camera controls switched on.
///
/// Runs the real controller capture path and the real stamping, hashing, fingerprinting, signing,
/// storage and sync code. Only the camera itself (a fixture JPEG), the camera-tuning bridge and the
/// scene analyzer are fakes. Platform plugins that tests cannot load (image compression, EXIF
/// writing, gallery) fail exactly as in other tests and the pipeline's existing fallbacks apply, so
/// this does not show that GPS EXIF is written on a phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<Map<String, dynamic>> uploads;
  late CameraRig rig;
  late GeoCameraController c;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('geocam_integrity_');
    HistoryStore.rootOverride = dir;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    uploads = [];
    SyncService.testClient = MockClient((req) async {
      uploads.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    });
    rig = CameraRig();
    final shot = File('${dir.path}/shot.jpg');
    // A camera-sized JPEG (a phone frame at this preset is at least 1920 px wide). The 417 px
    // fixture is too narrow for PhotoProcessor's QR sizing, which throws below ~490 px; that is a
    // separate, pre-existing limitation.
    final frame = img.Image(width: 1600, height: 1200);
    for (final p in frame) {
      p
        ..r = (p.x * 255) ~/ 1600
        ..g = (p.y * 255) ~/ 1200
        ..b = ((p.x ~/ 80 + p.y ~/ 80).isEven) ? 220 : 40;
    }
    rig.pictureBytes = Uint8List.fromList(img.encodeJpg(frame, quality: 90));
    await shot.writeAsBytes(rig.pictureBytes);
    rig.picturePath = shot.path;
    c = GeoCameraController(
      cameras: const [backCamera, frontCamera],
      tuningBridge: rig.bridge,
      sceneAnalyzer: rig.analyzer,
      cameraFactory: rig.create,
      analysisInterval: const Duration(hours: 1), // no analysis ticks during this test
    );
  });

  tearDown(() async {
    c.dispose();
    SyncService.testClient = null;
    HistoryStore.rootOverride = null;
    SyncService.stopAutoRetry();
    await dir.delete(recursive: true);
  });

  test('photo taken with manual controls and Presentation Mode: record integrity is unchanged', () async {
    await c.initializeCamera();
    await pumpEventQueue();
    await c.applyTuning(c.tuning.copyWith(awbMode: 5, evIndex: 2, focus: FocusControl.manual, focusDiopters: 1.5));
    await c.setPresentationMode(true);
    c.position = Position(
      latitude: 26.912434,
      longitude: 75.787270,
      timestamp: DateTime.utc(2026, 10, 1, 9),
      accuracy: 6.5,
      altitude: 431.2,
      altitudeAccuracy: 3,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    c.address = 'Lecture Hall 2, Jaipur';

    final result = await c.capture(allowWeakGps: true);
    expect(result, isNotNull);
    final finalBytes = await result!.processed;

    // Wait for the record to be stored and uploaded (both run in the background).
    for (var i = 0; i < 100 && uploads.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final record = (await HistoryStore.load()).single;
    expect(uploads, hasLength(1));

    // 1-2. The stamp (panel + QR) was applied: the final image is taller than the camera image.
    final raw = await _size(rig.pictureBytes);
    final stamped = await _size(finalBytes);
    expect(stamped.width, raw.width);
    expect(stamped.height, greaterThan(raw.height));

    // 4. Hash and fingerprint are of the final bytes, and those are the bytes stored.
    final stored = await File(record.stampedPath).readAsBytes();
    expect(stored, finalBytes);
    expect(record.mediaSha256, crypto.sha256.convert(finalBytes).toString());
    final manifest = await FingerprintService.generate(finalBytes);
    expect(manifest, isNotNull);
    expect(record.fpSha256, manifest!.sha256Digest);
    expect(record.regionFingerprints, manifest.toCanonicalJson());
    expect(record.imageDimensions, '${stamped.width}x${stamped.height}');
    expect(record.protocolVersion, 3);
    expect(record.latitude, 26.912434);
    expect(record.address, 'Lecture Hall 2, Jaipur');

    // 5. The signature covers the expected v3 record and nothing else.
    Future<bool> verify({required String mediaSha256}) => HashService.verify(
          proto: 3,
          storedSignature: record.signature,
          publicKey: record.publicKey,
          recordId: record.id,
          mediaType: 'photo',
          timestamp: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          accuracy: record.accuracy,
          altitude: record.altitude,
          address: record.address,
          mediaSha256: mediaSha256,
          imageDimensions: record.imageDimensions,
          fpVersion: record.fpVersion,
          fpSha256: record.fpSha256,
        );
    expect(await verify(mediaSha256: record.mediaSha256), isTrue);
    expect(await verify(mediaSha256: crypto.sha256.convert(utf8.encode('other')).toString()), isFalse);
    final canonical = HashService.canonicalMessage(
      proto: 3,
      recordId: record.id,
      mediaType: 'photo',
      timestamp: record.timestamp,
      latitude: record.latitude,
      longitude: record.longitude,
      accuracy: record.accuracy,
      altitude: record.altitude,
      address: record.address,
      mediaSha256: record.mediaSha256,
      imageDimensions: record.imageDimensions,
      fpVersion: record.fpVersion,
      fpSha256: record.fpSha256,
    );
    expect(canonical.split('|').map((f) => f.split('=').first).toList(),
        ['v', 'id', 'type', 'ts', 'lat', 'lng', 'acc', 'alt', 'addr64', 'media_sha256', 'img', 'fp_version', 'fp_sha256']);

    // Verification of the received file keeps its meaning: the exact file is an exact match.
    final check = await FingerprintService.verify(
      receivedBytes: finalBytes,
      expectedMediaSha256: record.mediaSha256,
      signatureValid: true,
      manifest: RegionFingerprintManifest.parseJson(record.regionFingerprints),
    );
    expect(check.outcome, VerificationOutcome.exactMatch);

    // 6. Stored and uploaded fields are exactly the existing ones: no camera settings, face boxes or
    // scene measurements are added to the record.
    expect(record.toJson().keys.toSet(), {
      'protocolVersion', 'id', 'stampedPath', 'originalPath', 'mediaType', 'timestamp', 'latitude', 'longitude',
      'accuracy', 'altitude', 'address', 'signature', 'mediaSha256', 'publicKey', 'syncStatus', 'imageDimensions',
      'fpVersion', 'fpSha256', 'regionFingerprints',
    });
    expect(uploads.single.keys.toSet(), {
      'protocolVersion', 'id', 'timestamp', 'latitude', 'longitude', 'accuracy', 'altitude', 'address', 'mediaType',
      'signature', 'mediaSha256', 'publicKey', 'imageDimensions', 'fpVersion', 'fpSha256', 'regionFingerprints',
    });
    expect(uploads.single['mediaSha256'], record.mediaSha256);
    expect(jsonEncode(uploads.single).length, lessThan(4000), reason: 'metadata only, no image bytes');

    // The camera's temporary file is removed as before.
    expect(File(rig.picturePath).existsSync(), isFalse);
  });

  test('older protocol-2 records still verify', () async {
    final sha = crypto.sha256.convert(utf8.encode('legacy')).toString();
    final sig = await HashService.sign(
      recordId: 'GC-OLD-1',
      mediaType: 'photo',
      timestamp: DateTime.utc(2025, 5, 1),
      latitude: 1.5,
      longitude: 2.5,
      accuracy: 10,
      altitude: 0,
      address: 'Old',
      mediaSha256: sha,
    );
    final ok = await HashService.verify(
      storedSignature: sig,
      publicKey: await HashService.getPublicKey(),
      recordId: 'GC-OLD-1',
      mediaType: 'photo',
      timestamp: DateTime.utc(2025, 5, 1),
      latitude: 1.5,
      longitude: 2.5,
      accuracy: 10,
      altitude: 0,
      address: 'Old',
      mediaSha256: sha,
    );
    expect(ok, isTrue);
  });
}

Future<({int width, int height})> _size(Uint8List bytes) async {
  final image = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
  return (width: image.width, height: image.height);
}
