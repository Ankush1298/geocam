import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../download_helper/download_helper.dart';
import '../../models/geo_record.dart';
import '../../services/hash_service.dart';

class HistoryDetailPage extends StatefulWidget {
  final GeoRecord record;
  const HistoryDetailPage({super.key, required this.record});

  @override
  State<HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends State<HistoryDetailPage> {
  VideoPlayerController? _video;
  /// `null` = not yet verified; `true` = OK; `false` = tampered / unknown.
  bool? _verified;

  @override
  void initState() {
    super.initState();
    if (widget.record.isVideo) {
      _video = VideoPlayerController.file(File(widget.record.stampedPath))
        ..initialize().then((_) {
          if (mounted) setState(() {});
        });
    }
    _verifyIntegrity();
  }

  Future<void> _verifyIntegrity() async {
    final record = widget.record;
    if (record.hash.isEmpty) {
      // Pre-signing record — cannot verify.
      setState(() => _verified = null);
      return;
    }
    final ok = await HashService.verify(
      storedSignature: record.hash,
      recordId: record.id,
      timestamp: record.timestamp,
      latitude: record.latitude,
      longitude: record.longitude,
      accuracy: record.accuracy,
      address: record.address,
    );
    if (mounted) setState(() => _verified = ok);
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _export(BuildContext context) async {
    final file = File(widget.record.stampedPath);
    final bytes = await file.readAsBytes();
    await downloadFile(bytes, '${widget.record.id}.${widget.record.isVideo ? 'mp4' : 'jpg'}');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.record.isVideo ? 'Video exported.' : 'Photo exported.')),
      );
    }
  }

  Widget _buildIntegrityBadge() {
    final record = widget.record;
    if (record.hash.isEmpty) {
      return _badge(
        icon: Icons.lock_open,
        label: 'No signature',
        sublabel: 'Captured before signing was enabled',
        color: Colors.grey,
      );
    }
    if (_verified == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Verifying integrity…'),
        ]),
      );
    }
    if (_verified == true) {
      return _badge(
        icon: Icons.verified_user,
        label: '✅ Data Verified',
        sublabel: 'Location, time & address match the original signature',
        color: Colors.greenAccent,
      );
    }
    return _badge(
      icon: Icons.gpp_bad,
      label: '❌ Tampered / Invalid',
      sublabel: 'The metadata does not match the original signature.\n'
          'Location, time or address may have been altered.',
      color: Colors.redAccent,
    );
  }

  Widget _badge({
    required IconData icon,
    required String label,
    required String sublabel,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 3),
              Text(sublabel,
                  style: const TextStyle(fontSize: 12, color: Colors.white70)),
              if (widget.record.hash.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'SIG: ${widget.record.hash.length > 16 ? '${widget.record.hash.substring(0, 16)}...' : widget.record.hash}',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11, color: Colors.white54),
                ),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    return Scaffold(
      appBar: AppBar(
        title: Text(record.id),
        actions: [IconButton(onPressed: () => _export(context), icon: const Icon(Icons.ios_share))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: record.isVideo
                ? (_video?.value.isInitialized == true
                    ? AspectRatio(
                        aspectRatio: _video!.value.aspectRatio,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            VideoPlayer(_video!),
                            IconButton.filled(
                              iconSize: 34,
                              onPressed: () {
                                if (_video!.value.isPlaying) {
                                  _video!.pause();
                                } else {
                                  _video!.play();
                                }
                                setState(() {});
                              },
                              icon: Icon(_video!.value.isPlaying ? Icons.pause : Icons.play_arrow),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())))
                : Image.file(File(record.stampedPath)),
          ),
          const SizedBox(height: 16),
          // ── Integrity badge ──────────────────────────────────────────────
          _buildIntegrityBadge(),
          const SizedBox(height: 8),
          Text('Capture details', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (record.latitude != null) Text('Latitude: ${record.latitude!.toStringAsFixed(6)}'),
          if (record.longitude != null) Text('Longitude: ${record.longitude!.toStringAsFixed(6)}'),
          if (record.accuracy != null) Text('Accuracy: ±${record.accuracy!.round()} m'),
          if (record.altitude != null) Text('Altitude: ${record.altitude!.toStringAsFixed(1)} m'),
          Text('Captured: ${record.timestamp.toLocal()}'),
          if (record.address.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(record.address, style: const TextStyle(color: Colors.white70)),
          ],
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => _export(context),
            icon: const Icon(Icons.download),
            label: Text(record.isVideo ? 'Export stamped video' : 'Export stamped photo'),
          ),
        ],
      ),
    );
  }
}
