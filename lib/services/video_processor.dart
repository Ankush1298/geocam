import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import '../core/theme/app_theme.dart';
import '../models/stamp_settings.dart';
import 'photo_processor.dart';

class VideoProcessor {
  /// Probes the video width using FFprobe so the panel can be rendered
  /// at the exact native resolution — matching how the photo processor works.
  Future<int> _probeVideoWidth(String inputPath) async {
    final session = await FFmpegKit.execute(
      '-v error -select_streams v:0 -show_entries stream=width '
      '-of csv=p=0 ${_quote(inputPath)}',
    );
    final output = await session.getOutput() ?? '';
    final parsed = int.tryParse(output.trim());
    return parsed != null && parsed > 0 ? parsed : 1080;
  }

  Future<String> stampVideo({
    required String inputPath,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    bool isFrontCamera = false,
  }) async {
    if (!settings.pixelEmbeddedStamps && !isFrontCamera) return inputPath;

    // Determine the real pixel width of the video so the panel is rendered
    // at the same resolution — identical to how photo_processor.dart works.
    final videoWidth = await _probeVideoWidth(inputPath);

    final dir = await getTemporaryDirectory();
    final overlayPath = '${dir.path}/$recordId-overlay.png';
    final outputPath = '${dir.path}/$recordId-geocam.mp4';
    final panel = await _buildPanel(
      position: position,
      address: address,
      timestamp: timestamp,
      recordId: recordId,
      settings: settings,
      outW: videoWidth.toDouble(),
    );
    await File(overlayPath).writeAsBytes(panel.bytes, flush: true);

    final input = _quote(inputPath);
    final overlayFile = _quote(overlayPath);
    final output = _quote(outputPath);

    // The panel PNG is already the exact same width as the video, so we only
    // need to pad the video vertically and overlay — no scaling at all.
    // This is the same approach as the photo processor (panel appended below).
    // Front-camera video gets the same single un-mirror as photos.
    final flip = isFrontCamera ? 'hflip,' : '';
    final filter = settings.pixelEmbeddedStamps
        ? '[0:v]${flip}pad=iw:ih+${panel.panelPixelHeight}:0:0:color=black[padded];[padded][1:v]overlay=0:H-h:format=auto[v]'
        : '[0:v]hflip[v]';

    final commandArgs = [
      '-y',
      '-i', input,
      if (settings.pixelEmbeddedStamps) ...['-i', overlayFile],
      '-filter_complex', filter,
      '-map', '[v]',
      '-map', '0:a?',
    ];

    final command = [
      ...commandArgs,
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '20',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-movflags', '+faststart',
      output,
    ].join(' ');

    final session = await FFmpegKit.execute(command);
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code) || !await File(outputPath).exists()) {
      throw StateError('Video watermark processing failed.');
    }

    try { await File(overlayPath).delete(); } catch (_) {}
    return outputPath;
  }

  Future<_Panel> _buildPanel({
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    required double outW,
  }) async {
    final lines = <String>[];
    if (settings.customText.trim().isNotEmpty) lines.add(settings.customText.trim());
    if (settings.showCoordinates) {
      lines.add(position == null
          ? 'Location not available'
          : '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}');
    }
    if (settings.showAddress) {
      lines.add(address.isEmpty ? 'Address not available' : address);
    }
    if (settings.showDateTime) lines.add(PhotoProcessor.formatDateTime(timestamp));
    if (settings.showAccuracy) {
      lines.add(position == null
          ? 'GPS accuracy: unavailable'
          : 'GPS accuracy: ±${position.accuracy.round()} m');
    }
    lines.add(recordId);

    final lineHeight = (outW * .030).clamp(42.0, 76.0).toDouble();
    final panelHeight = (lineHeight * lines.length + 36.0).clamp(150.0, double.infinity).toDouble();
    final qrSize = settings.showQr ? (panelHeight - 16).clamp(panelHeight * 0.78, outW * 0.46).toDouble() : 0.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, outW, panelHeight),
      Paint()..color = const Color(0xFF101214).withValues(alpha: .96),
    );

    final textMaxWidth = outW - (qrSize > 0 ? qrSize + 48 : 32);
    for (var i = 0; i < lines.length; i++) {
      final painter = TextPainter(
        text: TextSpan(
          text: lines[i],
          style: TextStyle(
            color: i == 0 ? AppTheme.amber : Colors.white,
            fontSize: i == 0 ? lineHeight * .72 : lineHeight * .56,
            fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: textMaxWidth);
      painter.paint(canvas, Offset(18, 14 + i * lineHeight));
    }

    if (settings.showQr) {
      final qrLeft = outW - qrSize - 18;
      final qrTop = (panelHeight - qrSize) / 2;
      PhotoProcessor.drawQr(
        canvas,
        PhotoProcessor().qrPayload(position, address, timestamp, recordId,
            mapLink: settings.qrMapLink),
        qrLeft,
        qrTop,
        qrSize,
      );
    }

    final image = await recorder.endRecording().toImage(outW.toInt(), panelHeight.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return _Panel(bytes!.buffer.asUint8List(), panelHeight.toInt());
  }

  String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
}

class _Panel {
  final Uint8List bytes;
  final int panelPixelHeight;

  const _Panel(this.bytes, this.panelPixelHeight);
}
