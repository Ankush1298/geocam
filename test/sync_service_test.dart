import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/camera/camera_controller.dart';
import 'package:geocam/models/geo_record.dart';
import 'package:geocam/services/hash_service.dart';
import 'package:geocam/services/history_store.dart';
import 'package:geocam/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<Map<String, dynamic>> requests;
  late int Function(http.Request) respond;
  Future<void> Function()? duringRequest;

  Future<void> addPhoto(String id) => HistoryStore.add(
        id: id,
        stamped: Uint8List.fromList([1, 2, 3]),
        original: Uint8List.fromList([1, 2, 3]),
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 1,
        longitude: 2,
        accuracy: 3,
        altitude: 4,
        address: 'x',
        signature: 'sig',
        mediaSha256: 'a' * 64,
        publicKey: 'key',
        imageDimensions: '10x10',
        fpVersion: 1,
        fpSha256: 'b' * 64,
        regionFingerprints: '{}',
      );

  Future<Map<String, String>> statuses() async =>
      {for (final r in await HistoryStore.load()) r.id: r.syncStatus};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('geocam_sync_test_');
    HistoryStore.rootOverride = dir;
    SharedPreferences.setMockInitialValues({});
    requests = [];
    respond = (_) => 200;
    duringRequest = null;
    SyncService.testClient = MockClient((req) async {
      await duringRequest?.call();
      final code = respond(req);
      if (code == -1) throw const SocketException('offline');
      requests.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', code);
    });
  });

  tearDown(() async {
    SyncService.testClient = null;
    HistoryStore.rootOverride = null;
    SyncService.stopAutoRetry();
    await dir.delete(recursive: true);
  });

  test('success: metadata-only payload, record marked synced', () async {
    await addPhoto('GC-A');
    await SyncService.syncPending();
    expect(await statuses(), {'GC-A': 'synced'});
    expect(requests.single['protocolVersion'], 3);
    expect(requests.single.keys, isNot(contains('media')));
    expect(jsonEncode(requests.single).length, lessThan(2000));
  });

  test(
      'offline: marked failed, stops after the first failure, later retry succeeds',
      () async {
    await addPhoto('GC-A');
    await addPhoto('GC-B');
    await addPhoto('GC-C');
    var attempts = 0;
    respond = (_) {
      attempts++;
      return -1;
    };
    await SyncService.syncPending();
    expect(attempts, 1);
    expect((await statuses()).values.where((s) => s == 'failed').length, 1);
    expect((await statuses()).values.where((s) => s == 'pending').length, 2);

    respond = (_) => 200;
    await SyncService.syncPending();
    expect((await statuses()).values.toSet(), {'synced'});
  });

  test('cloud verification off: no requests, nothing marked', () async {
    SharedPreferences.setMockInitialValues({'stamp.cloudVerification': false});
    await addPhoto('GC-A');
    await SyncService.syncPending();
    final saved = (await HistoryStore.load()).single;
    expect(await SyncService.sync(saved), isFalse);
    expect(requests, isEmpty);
    expect(await statuses(), {'GC-A': 'pending'});
  });

  test('overlapping scans upload each record once', () async {
    for (final id in ['GC-A', 'GC-B', 'GC-C']) {
      await addPhoto(id);
    }
    await Future.wait([
      SyncService.syncPending(),
      SyncService.syncPending(),
      SyncService.syncPending(),
    ]);
    expect(requests.map((r) => r['id']).toList()..sort(),
        ['GC-A', 'GC-B', 'GC-C']);
  });

  test('a record created during a scan is picked up by the follow-up pass',
      () async {
    await addPhoto('GC-A');
    var added = false;
    duringRequest = () async {
      if (added) return;
      added = true;
      await addPhoto('GC-B');
      SyncService.syncPending(); // arrives mid-scan
    };
    await SyncService.syncPending();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await statuses(), {'GC-A': 'synced', 'GC-B': 'synced'});
  });

  test('stale snapshot of an already synced record is not re-sent', () async {
    await addPhoto('GC-A');
    final stale = (await HistoryStore.load()).single;
    await SyncService.sync(stale);
    expect(requests.length, 1);
    expect(await SyncService.sync(stale), isTrue);
    expect(requests.length, 1);
  });

  test('permanent rejection (400) is not retried; server not ready (404) is',
      () async {
    await addPhoto('GC-A');
    respond = (_) => 400;
    await SyncService.syncPending();
    expect(await statuses(), {'GC-A': 'rejected'});
    await SyncService.syncPending();
    expect(requests.length, 1);

    await HistoryStore.delete((await HistoryStore.load()).single);
    await addPhoto('GC-B');
    respond = (_) => 404;
    await SyncService.syncPending();
    expect(await statuses(), {'GC-B': 'failed'});
    respond = (_) => 200;
    await SyncService.syncPending();
    expect(await statuses(), {'GC-B': 'synced'});
  });

  test('video records are stored and sent as protocol v2', () async {
    final f = File('${dir.path}/in.mp4')..writeAsBytesSync([9, 9, 9]);
    await HistoryStore.addVideo(
      id: 'GC-V',
      stampedPath: f.path,
      originalPath: f.path,
      timestamp: DateTime.utc(2026, 1, 1),
      latitude: null,
      longitude: null,
      accuracy: null,
      altitude: null,
      address: '',
      signature: 's',
      mediaSha256: 'c' * 64,
      publicKey: 'k',
    );
    final rec = (await HistoryStore.load()).single;
    expect(rec.protocolVersion, 2);
    await SyncService.syncPending();
    expect(requests.single['protocolVersion'], 2);
    expect(
        GeoRecord.fromJson({...rec.toJson(), 'protocolVersion': 3})
            .protocolVersion,
        2);
  });

  test('auto-retry start/stop is idempotent', () {
    SyncService.startAutoRetry();
    SyncService.startAutoRetry();
    SyncService.stopAutoRetry();
    SyncService.stopAutoRetry();
  });

  test('canonical message matches the server golden vector', () {
    final msg = HashService.canonicalMessage(
      proto: 3,
      recordId: 'GC-GOLD-1',
      mediaType: 'photo',
      timestamp: DateTime.utc(2026, 10, 3, 16, 12, 10, 574, 280),
      latitude: 25.033919,
      longitude: 74.634770,
      accuracy: 50.8,
      altitude: 383.3,
      address: 'Test, India',
      mediaSha256: 'ab' * 32,
      imageDimensions: '3024x4032',
      fpVersion: 1,
      fpSha256: 'cd' * 32,
    );
    expect(
      msg,
      'v=3|id=GC-GOLD-1|type=photo|ts=2026-10-03T16:12:10.574280Z|lat=25.033919|'
      'lng=74.634770|acc=50.8|alt=383.3|addr64=VGVzdCwgSW5kaWE=|media_sha256=${'ab' * 32}'
      '|img=3024x4032|fp_version=1|fp_sha256=${'cd' * 32}',
    );
  });

  test('GPS quality label is based on reported accuracy in metres', () {
    expect(GeoCameraController.gpsQualityLabel(null), 'Waiting for GPS');
    expect(GeoCameraController.gpsQualityLabel(8), 'GPS excellent (±8 m)');
    expect(GeoCameraController.gpsQualityLabel(25), 'GPS good (±25 m)');
    expect(GeoCameraController.gpsQualityLabel(100), 'GPS moderate (±100 m)');
    expect(GeoCameraController.gpsQualityLabel(101), 'GPS weak (±101 m)');
  });
}
