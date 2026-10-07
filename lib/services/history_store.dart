import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/geo_record.dart';

class HistoryStore {
  static Future<void> _writeQueue = Future<void>.value();

  static Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeQueue.then((_) => operation());
    _writeQueue = next.catchError((_) {});
    return next;
  }
  static Future<Directory> _root() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/geocam_records');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _indexFile() async {
    final dir = await _root();
    return File('${dir.path}/records.json');
  }

  static Future<List<GeoRecord>> load() async {
    if (kIsWeb) return <GeoRecord>[];
    try {
      final f = await _indexFile();
      if (!await f.exists()) return <GeoRecord>[];
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return <GeoRecord>[];
      final records = <GeoRecord>[];
      for (final e in decoded.whereType<Map>()) {
        try {
          final r = GeoRecord.fromJson(Map<String, dynamic>.from(e));
          if (await File(r.stampedPath).exists()) records.add(r);
        } catch (_) {}
      }
      records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return records;
    } catch (_) {
      return <GeoRecord>[];
    }
  }

  static Future<void> _write(List<GeoRecord> records) async {
    final f = await _indexFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> add({
    required String id,
    required Uint8List stamped,
    required Uint8List original,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String signature,
    required String mediaSha256,
    required String publicKey,
    String syncStatus = 'pending',
  }) async {
    if (kIsWeb) return;
    final dir = await _root();
    final stampedPath = '${dir.path}/$id-stamped.jpg';
    // Keep only the final stamped media in app storage. The permanent
    // Gallery copy is handled separately by `gal`; retaining a second full
    // original doubles storage usage on low-storage devices.
    final originalPath = stampedPath;
    await File(stampedPath).writeAsBytes(stamped, flush: true);
    await _enqueue(() => _insertAndTrim(GeoRecord(
      id: id,
      stampedPath: stampedPath,
      originalPath: originalPath,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      altitude: altitude,
      address: address,
      signature: signature,
      mediaSha256: mediaSha256,
      publicKey: publicKey,
      syncStatus: syncStatus,
    )));
  }

  static Future<void> addVideo({
    required String id,
    required String stampedPath,
    required String originalPath,
    required DateTime timestamp,
    required double? latitude,
    required double? longitude,
    required double? accuracy,
    required double? altitude,
    required String address,
    required String signature,
    required String mediaSha256,
    required String publicKey,
    String syncStatus = 'pending',
  }) async {
    if (kIsWeb) return;
    final dir = await _root();
    final stampedCopy = File('${dir.path}/$id-stamped.mp4');
    // Keep one in-app copy. The phone Gallery has its own independent copy.
    await File(stampedPath).copy(stampedCopy.path);
    final originalCopy = stampedCopy;
    await _enqueue(() => _insertAndTrim(GeoRecord(
      id: id,
      stampedPath: stampedCopy.path,
      originalPath: originalCopy.path,
      mediaType: 'video',
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      altitude: altitude,
      address: address,
      signature: signature,
      mediaSha256: mediaSha256,
      publicKey: publicKey,
      syncStatus: syncStatus,
    )));
  }

  static Future<void> _insertAndTrim(GeoRecord record) async {
    final current = await load();
    current.removeWhere((r) => r.id == record.id);
    current.insert(0, record);
    final trimmed = current.take(100).toList();
    final removed = current.skip(100).toList();
    for (final r in removed) {
      try { await File(r.stampedPath).delete(); } catch (_) {}
      try { await File(r.originalPath).delete(); } catch (_) {}
    }
    await _write(trimmed);
  }

  static Future<void> updateSyncStatus(String id, String status) async {
    await _enqueue(() async {
      final current = await load();
      final index = current.indexWhere((r) => r.id == id);
      if (index < 0) return;
      final r = current[index];
      current[index] = GeoRecord(
        id: r.id, stampedPath: r.stampedPath, originalPath: r.originalPath,
        mediaType: r.mediaType, timestamp: r.timestamp, latitude: r.latitude,
        longitude: r.longitude, accuracy: r.accuracy, altitude: r.altitude,
        address: r.address, signature: r.signature, mediaSha256: r.mediaSha256,
        publicKey: r.publicKey, syncStatus: status,
      );
      await _write(current);
    });
  }

  static Future<void> delete(GeoRecord record) async {
    if (kIsWeb) return;
    await _enqueue(() async {
      try {
        final stamped = File(record.stampedPath);
        final original = File(record.originalPath);
        if (await stamped.exists()) await stamped.delete();
        if (await original.exists()) await original.delete();
        final current = await load();
        current.removeWhere((r) => r.id == record.id);
        await _write(current);
      } catch (_) {}
    });
  }

}
