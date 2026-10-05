import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/geo_record.dart';
import '../../services/history_store.dart';
import 'history_detail_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<GeoRecord> records = <GeoRecord>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await HistoryStore.load();
    if (mounted) setState(() { records = loaded; loading = false; });
  }

  String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _delete(GeoRecord record) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete record?'),
        content: const Text('This removes the saved original and stamped image from GeoCam.'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.amber))
          : records.isEmpty
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.photo_library_outlined, size: 56, color: Colors.white38), SizedBox(height: 12), Text('No GeoCam records yet'), SizedBox(height: 4), Text('Your captured photos and videos will appear here.', style: TextStyle(color: Colors.white54))]))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final record = records[index];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryDetailPage(records: records, initialIndex: index))),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(children: [
                            SizedBox(
                              width: 100,
                              height: 82,
                              child: record.isVideo
                                  ? Container(
                                      color: Colors.black45,
                                      child: const Center(child: Icon(Icons.play_circle_fill, size: 40)),
                                    )
                                  : Image.file(
                                      File(record.stampedPath),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [Icon(record.isVideo ? Icons.videocam : Icons.photo, size: 16), const SizedBox(width: 6), Expanded(child: Text(record.id, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis))]),
                              const SizedBox(height: 4),
                              Text(_date(record.timestamp), style: const TextStyle(color: Colors.white70)),
                              if (record.latitude != null) Text('±${record.accuracy?.round() ?? 0} m  •  ${record.latitude!.toStringAsFixed(5)}, ${record.longitude!.toStringAsFixed(5)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              if (record.address.isNotEmpty) Text(record.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                            ])),
                            IconButton(tooltip: 'Delete', onPressed: () => _delete(record), icon: const Icon(Icons.delete_outline)),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
