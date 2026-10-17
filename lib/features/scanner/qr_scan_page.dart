import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Live camera QR reader. Pops with the first decoded text; nothing is uploaded.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan GeoCam QR')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Camera unavailable. Allow camera permission, or paste the link instead.',
                    textAlign: TextAlign.center),
              ),
            ),
          ),
          const Positioned(
            left: 0, right: 0, bottom: 32,
            child: Text('Point the camera at the QR code on the photo',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
