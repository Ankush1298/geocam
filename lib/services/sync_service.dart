import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/geo_record.dart';
import 'history_store.dart';

class SyncService {
  static const verificationBaseUrl = String.fromEnvironment(
    'GEOCAM_VERIFICATION_URL',
    defaultValue: 'https://geocam-server.onrender.com',
  );
  static const Duration timeout = Duration(seconds: 7);
  static Future<void> _syncLock = Future<void>.value();

  static Future<bool> sync(GeoRecord record) async {
    // Serialize uploads so a temporary outage cannot create a pile of
    // concurrent 20-second requests on low-end phones.
    final next = _syncLock.then((_) => _syncOne(record));
    _syncLock = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  static Future<bool> _syncOne(GeoRecord record) async {
    try {
      final media = File(record.stampedPath);
      if (!await media.exists()) throw StateError('Stamped media is missing.');
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$verificationBaseUrl/sync'),
      )
        ..fields['record'] = jsonEncode({
          'protocolVersion': 2,
          'id': record.id,
          'timestamp': record.timestamp.toUtc().toIso8601String(),
          'latitude': record.latitude,
          'longitude': record.longitude,
          'accuracy': record.accuracy,
          'altitude': record.altitude,
          'address': record.address,
          'mediaType': record.mediaType,
          'signature': record.signature,
          'mediaSha256': record.mediaSha256,
          'publicKey': record.publicKey,
        })
        ..files.add(await http.MultipartFile.fromPath(
          'media',
          record.stampedPath,
          filename: '${record.id}.${record.isVideo ? 'mp4' : 'jpg'}',
        ));

      final response = await request.send().timeout(timeout);
      final body = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Sync failed (${response.statusCode}): $body');
      }
      await HistoryStore.updateSyncStatus(record.id, 'synced');
      return true;
    } catch (_) {
      await HistoryStore.updateSyncStatus(record.id, 'failed');
      return false;
    }
  }

  static Future<void> syncPending() async {
    final records = await HistoryStore.load();
    for (final record in records.where((r) => r.syncStatus != 'synced')) {
      await sync(record);
    }
  }
}
