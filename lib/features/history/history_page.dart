import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_theme.dart';
import '../../models/geo_record.dart';
import '../../services/history_store.dart';
import 'history_detail_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> with WidgetsBindingObserver {
  List<GeoRecord> records = <GeoRecord>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final loaded = await HistoryStore.load();
    if (!mounted) return;
    setState(() {
      records = loaded;
      loading = false;
    });
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _delete(GeoRecord record) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from GeoCam?'),
        content: const Text(
          'This removes the item from GeoCam history only. '
          'The copy already saved to your phone Gallery/Google Photos is not deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) {
      await HistoryStore.delete(record);
      await _load();
    }
  }

  Future<void> _open(int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryDetailPage(
          records: records,
          initialIndex: index,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gallery'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.amber))
          : records.isEmpty
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 180),
                      Icon(Icons.photo_library_outlined, size: 64, color: Colors.white38),
                      SizedBox(height: 14),
                      Center(child: Text('No GeoCam captures yet')),
                      SizedBox(height: 5),
                      Center(
                        child: Text(
                          'Photos and videos you capture will appear here.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(4),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 3,
                      mainAxisSpacing: 3,
                      childAspectRatio: 1,
                    ),
                    itemCount: records.length,
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return _GalleryTile(
                        record: record,
                        date: _date(record.timestamp),
                        onTap: () => _open(index),
                        onLongPress: () => _delete(record),
                      );
                    },
                  ),
                ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  final GeoRecord record;
  final String date;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _GalleryTile({
    required this.record,
    required this.date,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(record.stampedPath);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (record.isVideo)
            _VideoThumb(file: file)
          else
            Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 480,
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Colors.black45,
                child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 34),
              ),
            ),
          if (record.isVideo)
            const Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.play_arrow, color: Colors.white, size: 28),
                ),
              ),
            ),
          Positioned(
            left: 4,
            right: 4,
            bottom: 4,
            child: Text(
              date,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: _SyncDot(status: record.syncStatus),
          ),
        ],
      ),
    );
  }
}

class _SyncDot extends StatelessWidget {
  final String status;
  const _SyncDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final synced = status == 'synced';
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: synced ? Colors.green.shade700 : Colors.orange.shade700,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white70, width: .7),
      ),
      child: Icon(
        synced ? Icons.cloud_done : Icons.cloud_upload,
        size: 11,
        color: Colors.white,
      ),
    );
  }
}

class _VideoThumb extends StatefulWidget {
  final File file;
  const _VideoThumb({required this.file});

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!await widget.file.exists()) return;
    final c = VideoPlayerController.file(widget.file);
    _controller = c;
    try {
      await c.initialize();
      await c.seekTo(Duration.zero);
      if (mounted) setState(() {});
    } catch (_) {
      await c.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c?.value.isInitialized != true) {
      return const ColoredBox(
        color: Colors.black54,
        child: Center(child: Icon(Icons.videocam_outlined, color: Colors.white54, size: 30)),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c!.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
