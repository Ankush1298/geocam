import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../models/geo_record.dart';
import '../models/stamp_settings.dart';
import 'history_store.dart';

enum _Outcome { ok, retry, rejected }

class SyncService {
  static const verificationBaseUrl = String.fromEnvironment(
    'GEOCAM_VERIFICATION_URL',
    defaultValue: 'https://geocam-server.onrender.com',
  );
  static const Duration timeout = Duration(seconds: 7);
  static const Duration retryInterval = Duration(minutes: 1);

  /// Tests inject a mock client; production creates one per request.
  @visibleForTesting
  static http.Client? testClient;

  static Future<void> _syncLock = Future<void>.value();

  static Future<bool> _enabled() async =>
      (await StampSettings.load()).cloudVerification;

  /// Uploads one record's signed metadata (never media bytes). Does nothing when
  /// cloud verification is off. Returns true once the server has the record.
  static Future<bool> sync(GeoRecord record) async =>
      await _run(record) == _Outcome.ok;

  static Future<_Outcome> _run(GeoRecord record) {
    // Serialize uploads so a temporary outage cannot create a pile of
    // concurrent requests on low-end phones. _syncOne never throws, so the
    // chain cannot get stuck.
    final next = _syncLock.then((_) => _syncOne(record));
    _syncLock = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  static Future<_Outcome> _syncOne(GeoRecord queued) async {
    try {
      if (!await _enabled()) return _Outcome.retry;
      // Use the stored state, not the snapshot taken when this was queued: the
      // record may have been synced or deleted in the meantime.
      final matches = (await HistoryStore.load()).where((r) => r.id == queued.id);
      if (matches.isEmpty) return _Outcome.rejected;
      final record = matches.first;
      if (record.syncStatus == 'synced') return _Outcome.ok;

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

      final uri = Uri.parse('$verificationBaseUrl/register');
      if (kReleaseMode && uri.scheme != 'https') {
        throw StateError('Refusing to sync over a non-HTTPS endpoint');
      }
      final client = testClient ?? http.Client();
      final http.Response response;
      try {
        response = await client
            .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload))
            .timeout(timeout);
      } finally {
        if (testClient == null) client.close();
      }

      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        await HistoryStore.updateSyncStatus(record.id, 'synced');
        return _Outcome.ok;
      }
      // 400/409/413/422: the server will never accept this exact record, so stop
      // retrying it every minute. Anything else (404/405 from an old server, 408,
      // 429, 5xx) is treated as temporary.
      if (const {400, 409, 413, 422}.contains(code)) {
        await HistoryStore.updateSyncStatus(record.id, 'rejected');
        return _Outcome.rejected;
      }
      throw HttpException('Sync failed ($code)');
    } catch (_) {
      try {
        await HistoryStore.updateSyncStatus(queued.id, 'failed');
      } catch (_) {}
      return _Outcome.retry;
    }
  }

  /// Fetch signed record metadata from `/api/record/<id>` for in-app verification.
  /// Never downloads media bytes.
  static Future<Map<String, dynamic>?> fetchRecord(String recordId) async {
    try {
      final response = await http.get(
        Uri.parse('$verificationBaseUrl/api/record/${Uri.encodeComponent(recordId)}'),
      ).timeout(timeout);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Timer? _timer;
  static _ResumeRetry? _observer;
  static bool _scanning = false;
  static bool _rescan = false;

  /// Retries unsynced records when the app returns to the foreground and every
  /// [retryInterval] while it is open. Safe to call repeatedly (camera controllers
  /// are recreated); there is one timer and one observer for the app's lifetime.
  static void startAutoRetry() {
    if (_timer != null) return;
    _observer = _ResumeRetry();
    WidgetsBinding.instance.addObserver(_observer!);
    _timer = Timer.periodic(retryInterval, (_) => syncPending());
  }

  @visibleForTesting
  static void stopAutoRetry() {
    _timer?.cancel();
    _timer = null;
    if (_observer != null) WidgetsBinding.instance.removeObserver(_observer!);
    _observer = null;
  }

  /// Uploads every pending/failed record, oldest-first order of storage. Only one
  /// scan runs at a time; a call made during a scan schedules one more pass so
  /// records created meanwhile are not stranded. Stops at the first network
  /// failure instead of timing out once per record.
  static Future<void> syncPending() async {
    if (_scanning) {
      _rescan = true;
      return;
    }
    _scanning = true;
    try {
      do {
        _rescan = false;
        if (!await _enabled()) return;
        final records = await HistoryStore.load();
        for (final r in records.where((r) => r.syncStatus == 'pending' || r.syncStatus == 'failed')) {
          if (!await _enabled()) return;
          if (await _run(r) == _Outcome.retry) break;
        }
      } while (_rescan);
    } catch (_) {
    } finally {
      _scanning = false;
    }
  }
}

class _ResumeRetry with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SyncService.syncPending();
  }
}
