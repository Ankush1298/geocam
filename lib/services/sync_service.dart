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
      final payload = {
        'protocolVersion': record.protocolVersion,
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
        if (record.imageDimensions != null) 'imageDimensions': record.imageDimensions,
        'fpVersion': record.fpVersion,
        if (record.fpSha256 != null) 'fpSha256': record.fpSha256,
        if (record.regionFingerprints != null) 'regionFingerprints': record.regionFingerprints,
      };

      final response = await http.post(
        Uri.parse('$verificationBaseUrl/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Sync failed (${response.statusCode}): ${response.body}');
      }
      await HistoryStore.updateSyncStatus(record.id, 'synced');
      return true;
    } catch (_) {
      await HistoryStore.updateSyncStatus(record.id, 'failed');
      return false;
    }
  }

  /// Fetch signed record metadata from `/api/record/<id>` for in-app verification.
  /// Never downloads media bytes.
  static Future<Map<String, dynamic>?> fetchRecord(String recordId) async {
    try {
      final response = await http.get(
        Uri.parse('$verificationBaseUrl/api/record/$recordId'),
      ).timeout(timeout);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> syncPending() async {
    final records = await HistoryStore.load();
    for (final record in records.where((r) => r.syncStatus != 'synced')) {
      await sync(record);
    }
  }
}
