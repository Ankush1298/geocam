import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import '../../services/hash_service.dart';

import '../../core/theme/app_theme.dart';
import '../../models/geo_record.dart';
import '../../services/fingerprint_service.dart';
import '../../services/history_store.dart';
import '../../services/sync_service.dart';

/// Shows the verification state for a GeoCam record and runs on-device
/// Layer A (exact-file) and Layer B (region fingerprint) checks.
class VerificationResultPage extends StatefulWidget {
  final String recordId;
  final Map<String, dynamic>? initialRecord;

  const VerificationResultPage({
    super.key,
    required this.recordId,
    this.initialRecord,
  });

  @override
  State<VerificationResultPage> createState() => _VerificationResultPageState();
}

class _VerificationResultPageState extends State<VerificationResultPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _record;
  RegionFingerprintManifest? _manifest;

  // Local file inspection
  bool _inspecting = false;
  String? _pickedFileName;
  VerificationResult? _verificationResult;

  @override
  void initState() {
    super.initState();
    if (widget.initialRecord != null) {
      _applyRecord(widget.initialRecord!);
    } else {
      _fetchRecord();
    }
  }

  Future<void> _fetchRecord() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final data = await SyncService.fetchRecord(widget.recordId);
    if (!mounted) return;

    if (data == null) {
      setState(() {
        _loading = false;
        _error = 'Record not found on server or network error. Record ID: ${widget.recordId}';
      });
      return;
    }

    _applyRecord(data);
  }

  /// Verifies the Ed25519 signature locally from the signed fields. The server's
  /// own `signatureValid` flag is never trusted.
  Future<bool> _verifyLocally(Map<String, dynamic> d) async {
    try {
      double? n(String k) => (d[k] as num?)?.toDouble();
      return await HashService.verify(
        proto: (d['protocolVersion'] as num?)?.toInt() ?? 2,
        storedSignature: (d['signature'] as String?) ?? '',
        publicKey: (d['publicKey'] as String?) ?? '',
        recordId: d['id'] as String,
        mediaType: d['mediaType'] as String,
        timestamp: DateTime.parse(d['timestamp'] as String),
        latitude: n('latitude'),
        longitude: n('longitude'),
        accuracy: n('accuracy'),
        altitude: n('altitude'),
        address: (d['address'] as String?) ?? '',
        mediaSha256: (d['mediaSha256'] as String?) ?? '',
        imageDimensions: d['imageDimensions'] as String?,
        fpVersion: (d['fpVersion'] as num?)?.toInt() ?? 0,
        fpSha256: d['fpSha256'] as String?,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyRecord(Map<String, dynamic> data) async {
    final sigOk = await _verifyLocally(data);
    // Region evidence is trusted only if it hashes to the signed fpSha256.
    RegionFingerprintManifest? manifest;
    final rawFp = data['regionFingerprints'] as String?;
    if (sigOk && rawFp != null && rawFp.isNotEmpty && rawFp.length <= 256 * 1024) {
      final m = RegionFingerprintManifest.parseJson(rawFp);
      if (m != null && m.sha256Digest == data['fpSha256'] && m.isWellFormed) manifest = m;
    }
    if (!mounted) return;

    setState(() {
      _loading = false;
      _record = {...data, 'signatureValid': sigOk};
      _manifest = manifest;
      _verificationResult = sigOk
          ? const VerificationResult(
              outcome: VerificationOutcome.recordAuthenticImageUnchecked,
              signatureValid: true,
              exactFileMatch: false,
              summary: 'Record is authentic, but no image was supplied for inspection.',
              details: 'The signature on the record verified on this device. Supply the received photo to verify its pixels.',
            )
          : const VerificationResult(
              outcome: VerificationOutcome.invalidSignature,
              signatureValid: false,
              exactFileMatch: false,
              summary: 'Digital signature on record is invalid or tampered.',
              details: 'The record could not be verified against its public key.',
            );
    });
  }

  Future<void> _analyzeFile(File file) async {
    final record = _record;
    if (record == null) return;

    try {
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File does not exist.')),
        );
        return;
      }

      setState(() {
        _inspecting = true;
        _pickedFileName = file.path.split('/').last;
      });

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        if (!mounted) return;
        setState(() => _inspecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File is empty.')),
        );
        return;
      }

      final result = await FingerprintService.verify(
        receivedBytes: bytes,
        expectedMediaSha256: (record['mediaSha256'] as String?) ?? '',
        signatureValid: record['signatureValid'] == true,
        manifest: _manifest,
      );

      if (!mounted) return;
      setState(() {
        _inspecting = false;
        _verificationResult = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _inspecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error analyzing image: $e')),
      );
    }
  }

  Future<void> _pickAndVerifyImage() async {
    final record = _record;
    if (record == null) return;

    // Load GeoCam history items
    List<GeoRecord> historyRecords = [];
    try {
      historyRecords = await HistoryStore.load();
    } catch (_) {}

    // Find any matching file in history for convenience
    GeoRecord? directMatch;
    for (final hr in historyRecords) {
      if (hr.id == widget.recordId) {
        directMatch = hr;
        break;
      }
    }

    // Look for files in Downloads / Pictures
    List<File> storagePhotos = [];
    final searchDirs = [
      Directory('/storage/emulated/0/Download'),
      Directory('/storage/emulated/0/Pictures'),
      Directory('/storage/emulated/0/DCIM/Camera'),
    ];
    for (final d in searchDirs) {
      try {
        if (d.existsSync()) {
          final entries = d.listSync();
          for (final e in entries.whereType<File>()) {
            final name = e.path.toLowerCase();
            if (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png')) {
              storagePhotos.add(e);
            }
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Select Photo to Verify',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Select a photo from local GeoCam records, storage, or enter a custom path.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 20),

                // Direct matching capture if present
                if (directMatch != null) ...[
                  () {
                    final match = directMatch!;
                    return Container(
                      decoration: BoxDecoration(
                        color: AppTheme.amber.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.amber.withValues(alpha: .5)),
                      ),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(match.stampedPath),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white38),
                          ),
                        ),
                        title: const Text('Matched Capture from this Device', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text(match.id, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: AppTheme.amber),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _analyzeFile(File(match.stampedPath));
                        },
                      ),
                    );
                  }(),
                  const SizedBox(height: 16),
                ],

                // GeoCam captures
                if (historyRecords.isNotEmpty) ...[
                  const Text('GeoCam Captures', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.amber)),
                  const SizedBox(height: 8),
                  ...historyRecords.take(15).map((hr) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(hr.stampedPath),
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.image, color: Colors.white24),
                          ),
                        ),
                        title: Text(hr.id, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Text(hr.timestamp.toLocal().toString().split('.').first, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _analyzeFile(File(hr.stampedPath));
                        },
                      )),
                  const SizedBox(height: 16),
                ],

                // Storage Photos (Downloads/Pictures)
                if (storagePhotos.isNotEmpty) ...[
                  const Text('Downloads & Storage Photos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.amber)),
                  const SizedBox(height: 8),
                  ...storagePhotos.take(15).map((f) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.photo, color: Colors.white70),
                        title: Text(f.path.split('/').last, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(f.parent.path, style: const TextStyle(fontSize: 11, color: Colors.white38)),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _analyzeFile(f);
                        },
                      )),
                  const SizedBox(height: 16),
                ],

                // System file picker (no storage permission needed; file stays on device)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.photo_library_outlined, color: AppTheme.amber),
                  title: const Text('Choose Received Photo', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Pick the photo from your gallery or files', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final res = await FilePicker.pickFiles(type: FileType.image);
                    final path = res?.files.single.path;
                    if (path != null) _analyzeFile(File(path));
                  },
                ),
                // Custom file path option
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.edit_note, color: AppTheme.amber),
                  title: const Text('Enter Custom File Path', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Type or paste absolute path to an image file', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final pathCtrl = TextEditingController();
                    final picked = await showDialog<String>(
                      context: context,
                      builder: (dCtx) => AlertDialog(
                        backgroundColor: AppTheme.panel,
                        title: const Text('Enter Image File Path'),
                        content: TextField(
                          controller: pathCtrl,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '/storage/emulated/0/Download/photo.jpg',
                            labelText: 'File Path',
                          ),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(dCtx).pop(), child: const Text('Cancel')),
                          FilledButton(
                            onPressed: () => Navigator.of(dCtx).pop(pathCtrl.text.trim()),
                            child: const Text('Analyze'),
                          ),
                        ],
                      ),
                    );
                    if (picked != null && picked.isNotEmpty) {
                      _analyzeFile(File(picked));
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo Verification'),
        backgroundColor: Colors.transparent,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.amber),
            SizedBox(height: 16),
            Text('Fetching signed record metadata…'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 14),
              const Text(
                'Record Verification Failed',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              FilledButton.tonal(
                onPressed: _fetchRecord,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final record = _record!;
    final vResult = _verificationResult;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Top status card
        _buildOutcomeCard(vResult),
        const SizedBox(height: 16),

        // Receiver local check CTA
        _buildInspectActionCard(),
        const SizedBox(height: 16),

        // Layer A + Layer B details
        if (vResult != null && _pickedFileName != null) ...[
          _buildAnalysisDetailsCard(vResult),
          const SizedBox(height: 16),
        ],

        // Record metadata card
        _buildMetadataCard(record),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildOutcomeCard(VerificationResult? result) {
    if (result == null) return const SizedBox.shrink();

    Color bgColor;
    Color accentColor;
    IconData icon;

    switch (result.outcome) {
      case VerificationOutcome.exactMatch:
        bgColor = const Color(0xFF1B382B);
        accentColor = const Color(0xFF4CAF50);
        icon = Icons.verified;
        break;
      case VerificationOutcome.modificationDetected:
        bgColor = const Color(0xFF421C1C);
        accentColor = const Color(0xFFE53935);
        icon = Icons.warning_amber_rounded;
        break;
      case VerificationOutcome.recordAuthenticImageUnchecked:
        bgColor = const Color(0xFF382F18);
        accentColor = AppTheme.amber;
        icon = Icons.shield_outlined;
        break;
      case VerificationOutcome.invalidSignature:
        bgColor = const Color(0xFF421C1C);
        accentColor = const Color(0xFFE53935);
        icon = Icons.gpp_bad_outlined;
        break;
      case VerificationOutcome.unableToVerify:
        bgColor = const Color(0xFF2B2B2E);
        accentColor = Colors.grey;
        icon = Icons.help_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: .5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.outcome.label,
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            result.summary,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            result.details,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectActionCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Check Received Photo',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Select the exact image file you received from the sender. GeoCam will check for tampering, cropping, and pixel modification entirely on your device.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (_pickedFileName != null) ...[
            Row(
              children: [
                const Icon(Icons.attach_file, size: 16, color: AppTheme.amber),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Selected: $_pickedFileName',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _inspecting ? null : _pickAndVerifyImage,
              icon: _inspecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.photo_library),
              label: Text(
                _inspecting
                    ? 'Analyzing image…'
                    : (_pickedFileName == null ? 'Select Photo from Device' : 'Select Another Photo'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisDetailsCard(VerificationResult result) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Inspection Layers',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const Divider(height: 20),

          // Layer A
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                result.exactFileMatch ? Icons.check_circle : Icons.cancel,
                color: result.exactFileMatch ? Colors.green : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Layer A: Exact-File Digest',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    Text(
                      result.exactFileMatch
                          ? 'Matches original file byte-for-byte.'
                          : 'File digest does not match original bytes (compression, metadata or pixel changes).',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Layer B
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                result.regionCheckPassed == true
                    ? Icons.check_circle
                    : (result.regionCheckPassed == false ? Icons.cancel : Icons.help_outline),
                color: result.regionCheckPassed == true
                    ? Colors.green
                    : (result.regionCheckPassed == false ? Colors.redAccent : Colors.grey),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Layer B: Region Fingerprint Grid',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    if (result.originalDimensions != null)
                      Text(
                        'Original: ${result.originalDimensions} • Received: ${result.testedDimensions ?? "Unknown"}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    if (result.totalRegions > 0) ...[
                      Text(
                        'Matching regions: ${result.matchingRegions} of ${result.totalRegions}',
                        style: TextStyle(
                          color: result.matchingRegions == result.totalRegions ? Colors.green : Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          // Visual region mini-grid if available
          if (result.regionMatches != null && result.regionMatches!.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Grid Analysis (8×8):',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            _buildMiniGrid(result.regionMatches!),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendItem(color: Colors.green, label: 'Unmodified'),
                SizedBox(width: 16),
                _LegendItem(color: Colors.redAccent, label: 'Modified / Missing'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMiniGrid(List<bool> matches) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
          ),
          itemCount: matches.length,
          itemBuilder: (context, index) {
            final ok = matches[index];
            return Container(
              decoration: BoxDecoration(
                color: ok ? Colors.green.withValues(alpha: .75) : Colors.redAccent.withValues(alpha: .85),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMetadataCard(Map<String, dynamic> record) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Signed Record Metadata',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const Divider(height: 20),
          _fieldRow('Record ID', record['id'] ?? '—'),
          _fieldRow('Timestamp', record['timestamp'] ?? '—'),
          _fieldRow('Media Type', record['mediaType'] ?? 'photo'),
          if (record['imageDimensions'] != null)
            _fieldRow('Original Dimensions', record['imageDimensions']),
          _fieldRow('Signature Status', record['signatureValid'] == true ? 'Valid (Ed25519)' : 'Invalid',
              color: record['signatureValid'] == true ? Colors.green : Colors.redAccent),
          _fieldRow('Key Fingerprint', record['keyFingerprint'] ?? '—'),
          _fieldRow('Media SHA-256', record['mediaSha256'] ?? '—', isMono: true),
          const SizedBox(height: 6),
          const Text(
            'Original media is never stored on the verification server.',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _fieldRow(String label, String value, {bool isMono = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontFamily: isMono ? 'monospace' : null,
              color: color ?? Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
      ],
    );
  }
}
