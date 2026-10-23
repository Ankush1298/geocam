import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/scanner/verification_result_page.dart';
import 'package:geocam/services/fingerprint_service.dart';
import 'package:geocam/services/hash_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  Future<Map<String, dynamic>> signedRecord({String? registeredAt, int? gpsOffsetMs}) async {
    final ts = DateTime.utc(2026, 10, 3, 16, 12, 10);
    final sha = 'a' * 64;
    final manifest = RegionFingerprintManifest(
      imageWidth: 8,
      imageHeight: 8,
      gridRows: 1,
      gridCols: 1,
      regions: ['0f0f0f0ff0f0f0f07f0'],
      gpsClockOffsetMs: gpsOffsetMs,
    );
    final raw = manifest.toCanonicalJson();
    final fpSha = crypto.sha256.convert(raw.codeUnits).toString();
    final sig = await HashService.sign(
      proto: 3, recordId: 'GC-T', mediaType: 'photo', timestamp: ts, latitude: null,
      longitude: null, accuracy: null, altitude: null, address: '', mediaSha256: sha,
      imageDimensions: '8x8', fpVersion: 2, fpSha256: fpSha,
    );
    return {
      'id': 'GC-T', 'protocolVersion': 3, 'timestamp': ts.toIso8601String(), 'mediaType': 'photo',
      'latitude': null, 'longitude': null, 'accuracy': null, 'altitude': null, 'address': '',
      'mediaSha256': sha, 'publicKey': await HashService.getPublicKey(), 'signature': sig,
      'imageDimensions': '8x8', 'fpVersion': 2, 'fpSha256': fpSha, 'regionFingerprints': raw,
      'keyFingerprint': 'abcd', if (registeredAt != null) 'registeredAt': registeredAt,
    };
  }

  Future<void> show(WidgetTester t, Map<String, dynamic> record) async {
    t.view.physicalSize = const Size(900, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(MaterialApp(home: VerificationResultPage(recordId: 'GC-T', initialRecord: record)));
    await t.pumpAndSettle();
  }

  testWidgets('shows server registration time, labelled as not the capture time, plus GPS clock check', (t) async {
    await show(t, await signedRecord(registeredAt: '2026-10-06T09:00:00.123456Z', gpsOffsetMs: 300000));
    // Shown in IST like everywhere else in the app: 09:00:00 UTC is 14:30:00 IST.
    expect(find.text('06/10/2026 14:30:00 IST'), findsOneWidget);
    expect(find.text('03/10/2026 21:42:10 IST'), findsOneWidget, reason: 'captured time, also IST');
    expect(find.text('2026-10-06T09:00:00.123456Z'), findsNothing);
    expect(find.textContaining('Registered on server (not the capture time)'), findsOneWidget);
    expect(find.textContaining('Captured (device clock, not independently verified)'), findsOneWidget);
    expect(find.textContaining('ahead of GPS time by 5 min'), findsOneWidget);
    expect(find.textContaining('may be wrong'), findsOneWidget);
    expect(find.textContaining('Consistency check only'), findsOneWidget);
  });

  testWidgets('older record without registeredAt or GPS reference degrades gracefully', (t) async {
    await show(t, await signedRecord());
    expect(find.text('Not recorded (older record)'), findsOneWidget);
    // No GPS time reference is normal indoors: no row and no error-like text.
    expect(find.textContaining('Phone clock vs GPS'), findsNothing);
    expect(find.textContaining('No GPS time reference'), findsNothing);
    expect(find.text('Valid (Ed25519)'), findsOneWidget);
  });

  testWidgets('a manifest whose bytes do not match the signed hash is ignored', (t) async {
    final r = await signedRecord(gpsOffsetMs: 0);
    r['regionFingerprints'] = (r['regionFingerprints'] as String).replaceFirst('"gpsClockOffsetMs":0,', '"gpsClockOffsetMs":999,');
    await show(t, r);
    expect(find.textContaining('Phone clock vs GPS'), findsNothing); // tampered manifest not trusted
  });
}
