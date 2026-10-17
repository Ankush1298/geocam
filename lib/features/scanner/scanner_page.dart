import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../models/geo_record.dart';
import '../../services/history_store.dart';
import 'qr_scan_page.dart';
import 'verification_result_page.dart';

/// Scanner and verification entry point.
/// Pure Dart implementation compatible with Shorebird OTA patches.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final TextEditingController _idController = TextEditingController();
  List<GeoRecord> _recentRecords = [];
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _checkClipboard();
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final records = await HistoryStore.load();
      if (mounted) {
        setState(() {
          _recentRecords = records.take(10).toList();
          _loadingHistory = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty) {
        final extracted = _extractRecordId(text);
        if (extracted != null && mounted) {
          _idController.text = extracted;
        }
      }
    } catch (_) {}
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (raw == null || !mounted) return;
    final id = _extractRecordId(raw);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That QR code is not a GeoCam record.')),
      );
      return;
    }
    _idController.text = id;
    _navigateToVerification(id);
  }

  String? _extractRecordId(String raw) {
    final directMatch = RegExp(r'\b(GC-[A-Za-z0-9_-]+)\b').firstMatch(raw);
    if (directMatch != null) {
      return directMatch.group(1);
    }

    try {
      final uri = Uri.parse(raw);
      if (uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.last;
        if (last.startsWith('GC-')) return last;
      }
    } catch (_) {}

    return null;
  }

  void _navigateToVerification(String recordId) {
    final cleanId = _extractRecordId(recordId) ?? recordId.trim();
    if (cleanId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid Record ID or URL.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerificationResultPage(recordId: cleanId),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty) {
        final extracted = _extractRecordId(text) ?? text;
        setState(() => _idController.text = extracted);
        _navigateToVerification(extracted);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Clipboard is empty.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read clipboard: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify Record'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppTheme.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.amber.withValues(alpha: .3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.amber.withValues(alpha: .2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.verified_user, color: AppTheme.amber, size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GeoCam Verification',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Zero-knowledge verification of tamper-proof photos',
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Scan the QR code on the photo, or enter the Record ID / paste the verification link.',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _idController,
                  decoration: InputDecoration(
                    hintText: 'e.g. GC-20261018-ABCD1234',
                    labelText: 'Record ID or Verification URL',
                    prefixIcon: const Icon(Icons.qr_code, color: AppTheme.amber),
                    suffixIcon: _idController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() => _idController.clear()),
                          )
                        : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onSubmitted: _navigateToVerification,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.amber,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _scanQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR Code'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: Colors.white.withValues(alpha: .2)),
                        ),
                        onPressed: _pasteFromClipboard,
                        icon: const Icon(Icons.content_paste, size: 18),
                        label: const Text('Paste Link/ID'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.amber,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _idController.text.trim().isEmpty
                            ? null
                            : () => _navigateToVerification(_idController.text),
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Verify Now', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Recent local captures section
          Row(
            children: [
              const Icon(Icons.history, size: 20, color: AppTheme.amber),
              const SizedBox(width: 8),
              const Text(
                'Recent Local Captures',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_loadingHistory)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 10),
          if (!_loadingHistory && _recentRecords.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.panel,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'No local captures found yet. Capture photos or paste an ID above.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            )
          else
            ..._recentRecords.map((r) => Card(
                  color: AppTheme.panel,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    leading: const CircleAvatar(
                      backgroundColor: Colors.black26,
                      child: Icon(Icons.photo_camera, color: AppTheme.amber, size: 20),
                    ),
                    title: Text(
                      r.id,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '${r.timestamp.toLocal().toString().split('.').first} • ${r.address.isEmpty ? "No address" : r.address}',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white38),
                    onTap: () => _navigateToVerification(r.id),
                  ),
                )),
        ],
      ),
    );
  }
}
