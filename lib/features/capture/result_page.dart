import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../download_helper/download_helper.dart';
import '../camera/camera_controller.dart';

class ResultPage extends StatefulWidget {
  final CaptureResult result;

  const ResultPage({super.key, required this.result});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  Uint8List? _processed;

  @override
  void initState() {
    super.initState();
    widget.result.processed.then((value) {
      if (!mounted) return;
      setState(() => _processed = value);
    }).catchError((_) {});
  }

  Future<void> _export(BuildContext context) async {
    final stamped = _processed ?? await widget.result.processed;
    if (!mounted) return;
    await downloadFile(stamped, '${widget.result.recordId}.jpg');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stamped photo exported.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    return Scaffold(
      appBar: AppBar(title: const Text('Capture result')),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 4,
              child: Center(
                child: Transform(
                  alignment: Alignment.center,
                  transform: _processed == null && result.isFrontCamera
                      ? Matrix4.diagonal3Values(-1.0, 1.0, 1.0)
                      : Matrix4.identity(),
                  child: Image.memory(
                    _processed ?? result.original,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(color: AppTheme.panel),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.check_circle, color: Colors.greenAccent),
                const SizedBox(width: 8),
                const Text('Photo captured', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Flexible(child: Text(result.recordId, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11))),
              ]),
              const SizedBox(height: 8),
              if (result.position != null)
                Text('📍 ${result.position!.latitude.toStringAsFixed(6)}, ${result.position!.longitude.toStringAsFixed(6)}  •  ±${result.position!.accuracy.round()} m'),
              if (result.address.isNotEmpty)
                Text(result.address, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
              Text('🕐 ${result.timestamp.toLocal()}', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.refresh), label: const Text('Retake'))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton.icon(onPressed: () => _export(context), icon: const Icon(Icons.ios_share), label: const Text('Export'))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
