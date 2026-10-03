import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/geo_record.dart';

class HistoryStore {
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
      final records = decoded
          .whereType<Map>()
          .map((e) => GeoRecord.fromJson(Map<String, dynamic>.from(e)))
          .where((r) => File(r.stampedPath).existsSync())
          .toList();
      records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return records;
    } catch (_) {
      return <GeoRecord>[];
    }
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
    String hash = '',
  }) async {
    if (kIsWeb) return;
    final dir = await _root();
    final stampedPath = '${dir.path}/$id-stamped.jpg';
    final originalPath = '${dir.path}/$id-original.jpg';
    await File(stampedPath).writeAsBytes(stamped, flush: true);
    await File(originalPath).writeAsBytes(original, flush: true);

    final current = await load();
    current.insert(
      0,
      GeoRecord(
        id: id,
        stampedPath: stampedPath,
        originalPath: originalPath,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        altitude: altitude,
        address: address,
        hash: hash,
      ),
    );

    final trimmed = current.take(100).toList();
    final f = await _indexFile();
    await f.writeAsString(
      jsonEncode(trimmed.map((r) => r.toJson()).toList()),
      flush: true,
    );
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
    String hash = '',
  }) async {
    if (kIsWeb) return;
    final dir = await _root();
    final stampedCopy = File('${dir.path}/$id-stamped.mp4');
    final originalCopy = File('${dir.path}/$id-original.mp4');
    await File(stampedPath).copy(stampedCopy.path);
    if (File(originalPath).existsSync()) {
      await File(originalPath).copy(originalCopy.path);
    } else {
      await stampedCopy.copy(originalCopy.path);
    }

    final current = await load();
    current.insert(
      0,
      GeoRecord(
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
        hash: hash,
      ),
    );

    final trimmed = current.take(100).toList();
    final f = await _indexFile();
    await f.writeAsString(
      jsonEncode(trimmed.map((r) => r.toJson()).toList()),
      flush: true,
    );
  }

  static Future<void> delete(GeoRecord record) async {
    // IMPORTANT: Never delete from the phone Gallery here. Gallery media is
    // stored in Android's shared MediaStore and intentionally survives
    // deletion of the corresponding GeoCam history record.
    try {
      final stamped = File(record.stampedPath);
      final original = File(record.originalPath);
      if (await stamped.exists()) await stamped.delete();
      if (await original.exists()) await original.delete();
      final current = await load();
      current.removeWhere((r) => r.id == record.id);
      final f = await _indexFile();
      await f.writeAsString(
        jsonEncode(current.map((r) => r.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }
}
