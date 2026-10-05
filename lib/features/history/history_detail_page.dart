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

  // Per-page state caches
  final Map<int, VideoPlayerController?> _videos = {};
  final Map<int, bool?> _verified = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _initPage(widget.initialIndex);
  }

  void _initPage(int index) {
    if (index < 0 || index >= widget.records.length) return;
    final record = widget.records[index];
    if (record.isVideo && _videos[index] == null) {
      final ctrl = VideoPlayerController.file(File(record.stampedPath))
        ..initialize().then((_) {
          if (mounted) setState(() {});
        });
      _videos[index] = ctrl;
    }
    if (!_verified.containsKey(index)) {
      _verifyIntegrity(index);
    }
  }

  Future<void> _verifyIntegrity(int index) async {
    final record = widget.records[index];
    if (record.hash.isEmpty) {
      if (mounted) setState(() => _verified[index] = null);
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
    if (mounted) setState(() => _verified[index] = ok);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final ctrl in _videos.values) {
      ctrl?.dispose();
    }
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

  Widget _buildIntegrityBadge(int index) {
    final record = widget.records[index];
    final verified = _verified[index];
    if (record.hash.isEmpty) {
      return _badge(
        icon: Icons.lock_open,
        label: 'No signature',
        sublabel: 'Captured before signing was enabled',
        color: Colors.grey,
        record: record,
      );
    }
    if (!_verified.containsKey(index) || verified == null && record.hash.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Verifying integrity…'),
        ]),
      );
    }
    if (verified == true) {
      return _badge(
        icon: Icons.verified_user,
        label: '✅ Data Verified',
        sublabel: 'Location, time & address match the original signature',
        color: Colors.greenAccent,
        record: record,
      );
    }
    return _badge(
      icon: Icons.gpp_bad,
      label: '❌ Tampered / Invalid',
      sublabel: 'The metadata does not match the original signature.\n'
          'Location, time or address may have been altered.',
      color: Colors.redAccent,
      record: record,
    );
  }

  Widget _badge({
    required IconData icon,
    required String label,
    required String sublabel,
    required Color color,
    required GeoRecord record,
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
              if (record.hash.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'SIG: ${record.hash.length > 16 ? '${record.hash.substring(0, 16)}...' : record.hash}',
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

  Widget _buildPage(BuildContext context, int index) {
    final record = widget.records[index];
    final video = _videos[index];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: record.isVideo
              ? (video?.value.isInitialized == true
                  ? AspectRatio(
                      aspectRatio: video!.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(video),
                          IconButton.filled(
                            iconSize: 34,
                            onPressed: () {
                              if (video.value.isPlaying) {
                                video.pause();
                              } else {
                                video.play();
                              }
                              setState(() {});
                            },
                            icon: Icon(video.value.isPlaying ? Icons.pause : Icons.play_arrow),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())))
              : Image.file(File(record.stampedPath)),
        ),
        const SizedBox(height: 16),
        // ── Integrity badge ─────────────────────────────────────────────
        _buildIntegrityBadge(index),
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
          onPressed: () => _export(context, record),
          icon: const Icon(Icons.download),
          label: Text(record.isVideo ? 'Export stamped video' : 'Export stamped photo'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.records.length;
    final record = widget.records[_currentIndex];
    return Scaffold(
      appBar: AppBar(
        title: Text('${_currentIndex + 1} / $total  •  ${record.id}'),
        actions: [
          IconButton(
            onPressed: () => _export(context, record),
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: total,
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
                _initPage(index);
              },
              itemBuilder: (context, index) => _buildPage(context, index),
            ),
          ),
          // ── Page indicator dots ────────────────────────────────────────
          if (total > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(total, (i) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _currentIndex ? 18 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _currentIndex
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white30,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }
}
