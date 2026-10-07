import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../download_helper/download_helper.dart';
import '../../models/geo_record.dart';
import '../../services/hash_service.dart';

class HistoryDetailPage extends StatefulWidget {
  final List<GeoRecord> records;
  final int initialIndex;

  const HistoryDetailPage({
    super.key,
    required this.records,
    required this.initialIndex,
  });

  @override
  State<HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends State<HistoryDetailPage> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _export(BuildContext context, GeoRecord record) async {
    final file = File(record.stampedPath);
    final bytes = await file.readAsBytes();
    await downloadFile(bytes, '${record.id}.${record.isVideo ? 'mp4' : 'jpg'}');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(record.isVideo ? 'Video exported.' : 'Photo exported.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.records.isEmpty) return const Scaffold();
    final record = widget.records[_currentIndex];
    return Scaffold(
      appBar: AppBar(
        title: Text(record.id),
        actions: [
          IconButton(
            onPressed: () => _export(context, record),
            icon: const Icon(Icons.ios_share),
          )
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.records.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return HistoryDetailItem(
            record: widget.records[index],
            onExport: () => _export(context, widget.records[index]),
          );
        },
      ),
    );
  }
}

class HistoryDetailItem extends StatefulWidget {
  final GeoRecord record;
  final VoidCallback onExport;

  const HistoryDetailItem({super.key, required this.record, required this.onExport});

  @override
  State<HistoryDetailItem> createState() => _HistoryDetailItemState();
}

class _HistoryDetailItemState extends State<HistoryDetailItem> {
  VideoPlayerController? _video;
  bool? _verified;
  bool? _mediaHashMatches;

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
    if (!record.hasCryptographicProof) {
      if (mounted) setState(() { _verified = null; _mediaHashMatches = null; });
      return;
    }
    try {
      final actualHash = await HashService.sha256File(record.stampedPath);
      final mediaOk = actualHash == record.mediaSha256;
      final signatureOk = await HashService.verify(
        storedSignature: record.signature,
        publicKey: record.publicKey,
        recordId: record.id,
        mediaType: record.mediaType,
        timestamp: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        accuracy: record.accuracy,
        altitude: record.altitude,
        address: record.address,
        mediaSha256: record.mediaSha256,
      );
      if (mounted) setState(() { _mediaHashMatches = mediaOk; _verified = mediaOk && signatureOk; });
    } catch (_) {
      if (mounted) setState(() { _mediaHashMatches = false; _verified = false; });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Widget _buildIntegrityBadge() {
    final record = widget.record;
    if (!record.hasCryptographicProof) {
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
        sublabel: 'Media bytes and signed capture metadata match.',
        color: Colors.greenAccent,
      );
    }
    return _badge(
      icon: Icons.gpp_bad,
      label: '❌ Tampered / Invalid',
      sublabel: 'The saved media or signed capture metadata does not match.\n'
          'The record should not be treated as verified.',
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
              if (widget.record.signature.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'SIG: ${widget.record.signature.length > 16 ? '${widget.record.signature.substring(0, 16)}...' : widget.record.signature}',
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
    return ListView(
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
        if (_mediaHashMatches != null) ...[
          Text('Media SHA-256: ${widget.record.mediaSha256}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white54)),
          const SizedBox(height: 8),
        ],
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
          onPressed: widget.onExport,
          icon: const Icon(Icons.download),
          label: Text(record.isVideo ? 'Export stamped video' : 'Export stamped photo'),
        ),
      ],
    );
  }
}
