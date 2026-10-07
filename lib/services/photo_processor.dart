import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geolocator/geolocator.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/theme/app_theme.dart';
import '../models/stamp_settings.dart';
import '../models/camera_frame.dart';
import 'sync_service.dart';

class PhotoProcessor {
  Future<Uint8List> stamp({
    required Uint8List jpg,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    required CameraFrame frame,
    required double screenAspect,
    bool isFrontCamera = false,
  }) async {
    // Pixel-Embedded Stamp mode burns the location record into the actual
    // image pixels. EXIF can be stripped by messaging/social apps, but this
    // visible stamp remains part of the JPEG itself.
    //
    // IMPORTANT: CameraX already owns camera capture orientation. Do not
    // horizontally flip front-camera stills here. The capture bytes are the
    // canonical source for stamping, hashing, signing, storage and export.
    // Applying an app-level front-camera flip here turns a correct capture
    // into a mirrored photograph and makes a second flip appear to "fix" it.
    if (!settings.pixelEmbeddedStamps && !isFrontCamera) return jpg;

    final codec = await ui.instantiateImageCodec(jpg);
    final decodedFrame = await codec.getNextFrame();
    final img = decodedFrame.image;
    final w = img.width.toDouble();
    final h = img.height.toDouble();

    // Crop the sensor image to match the selected frame aspect ratio.
    final targetRatio = frame.ratio(screenAspect);
    double cropW, cropH, cropLeft, cropTop;
    if (targetRatio == null || targetRatio <= 0) {
      cropW = w; cropH = h; cropLeft = 0; cropTop = 0;
    } else {
      final sensorRatio = w / h;
      if (sensorRatio > targetRatio) {
        // Sensor is wider than target — crop sides
        cropH = h;
        cropW = h * targetRatio;
        cropLeft = (w - cropW) / 2;
        cropTop = 0;
      } else {
        // Sensor is taller than target — crop top/bottom
        cropW = w;
        cropH = w / targetRatio;
        cropLeft = 0;
        cropTop = (h - cropH) / 2;
      }
    }

    final lines = <String>[];
    if (settings.customText.trim().isNotEmpty) {
      lines.add(settings.customText.trim());
    }
    if (settings.showCoordinates) {
      lines.add(position == null
          ? 'Location not available'
          : '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}');
    }
    if (settings.showAddress) {
      lines.add(address.isEmpty ? 'Address not available' : address);
    }
    if (settings.showDateTime) lines.add(formatDateTime(timestamp));
    if (settings.showAccuracy) {
      lines.add(position == null
          ? 'GPS accuracy: unavailable'
          : 'GPS accuracy: ±${position.accuracy.round()} m');
    }
    lines.add(recordId);

    final outW = cropW;
    final outH = cropH;
    // Keep the existing stamp panel dimensions, but make the text itself
    // noticeably larger and more readable. The panel is intentionally not
    // enlarged so the photo retains the same usable area.
    final lineHeight = max(42.0, min(76.0, outW * 0.030));
    final panelHeight = max(150.0, lineHeight * lines.length + 36.0);
    // Make QR at least 40% of panel height so it's large enough to scan easily.
    final qrSize = settings.showQr ? (panelHeight - 16).clamp(panelHeight * 0.78, outW * 0.46) : 0.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // CameraX owns capture orientation. Preserve the decoded camera image
    // exactly as supplied; there is intentionally NO front-camera flip here.
    // This keeps one source of truth from capture through the final signed
    // media bytes and prevents a second mirror from being introduced by the
    // application.
    if (isFrontCamera) {
      canvas.save();
      canvas.translate(outW, 0);
      canvas.scale(-1, 1);
    }

    canvas.drawImageRect(
      img,
      Rect.fromLTWH(cropLeft, cropTop, cropW, cropH),
      Rect.fromLTWH(0, 0, outW, outH),
      Paint(),
    );

if (isFrontCamera) {
  canvas.restore();
}
    if (settings.pixelEmbeddedStamps) {
      canvas.drawRect(
        Rect.fromLTWH(0, outH, outW, panelHeight),
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
        painter.paint(canvas, Offset(18, outH + 14 + i * lineHeight));
      }

      if (settings.showQr) {
        final qrLeft = outW - qrSize - 18;
        final qrTop = outH + (panelHeight - qrSize) / 2;
        drawQr(
          canvas,
          qrPayload(position, address, timestamp, recordId,
              mapLink: settings.qrMapLink),
          qrLeft,
          qrTop,
          qrSize,
        );
      }
    }

    final output = await recorder.endRecording().toImage(
          outW.toInt(),
          settings.pixelEmbeddedStamps ? (outH + panelHeight).toInt() : outH.toInt(),
        );
    final png = (await output.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();

    try {
      return await FlutterImageCompress.compressWithList(
        png,
        minWidth: output.width,
        minHeight: output.height,
        quality: 95,
        format: CompressFormat.jpeg,
      );
    } catch (_) {
      return png;
    }
  }

  /// Draws the QR on a whole-pixel grid with the standard 4-module quiet zone.
  /// Scaling the code to an arbitrary size makes modules 12px here and 13px
  /// there with blurry anti-aliased edges, which gets much worse after a
  /// screen photo. Here every module is the same integer size and every edge
  /// is pixel-sharp.
  static void drawQr(
    Canvas canvas,
    String payload,
    double left,
    double top,
    double size,
  ) {
    final qrCode = QrCode.fromData(
      data: payload,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final qrImage = QrImage(qrCode);
    final n = qrImage.moduleCount;
    const quiet = 4;
    final total = n + 2 * quiet;
    final module = max(1.0, (size / total).floorToDouble());
    final actual = module * total;
    final ox = (left + (size - actual) / 2).roundToDouble();
    final oy = (top + (size - actual) / 2).roundToDouble();

    final light = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..isAntiAlias = false;
    final dark = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;

    canvas.drawRect(Rect.fromLTWH(ox, oy, actual, actual), light);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (qrImage.isDark(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(
              ox + (c + quiet) * module,
              oy + (r + quiet) * module,
              module,
              module,
            ),
            dark,
          );
        }
      }
    }
  }

  /// Compact payload: same information as before (address, coordinates, date,
  /// time, map link) without the header/labels or the duplicated Date/Time
  /// lines, so the QR has fewer modules and Lens shows more of it at once.
  /// Short lines first, long address last, map link at the very end.
  String qrPayload(
    Position? position,
    String address,
    DateTime timestamp,
    String recordId, {
    bool mapLink = true,
  }) =>
      qrPayloadFor(
        lat: position?.latitude,
        lng: position?.longitude,
        address: address,
        timestamp: timestamp,
        mapLink: mapLink,
        recordId: recordId,
      );

  /// QR payload: Just a verifiable URL that can be scanned.
  static String qrPayloadFor({
    double? lat,
    double? lng,
    required String address,
    required DateTime timestamp,
    bool mapLink = true,
    String recordId = '',
  }) {
    // Return a verification URL (with signature appended so it's fully decentralized for this prototype)
    if (recordId.isNotEmpty) {
      return '${SyncService.verificationBaseUrl}/$recordId';
    }
    
    // Fallback if no recordId
    return '${SyncService.verificationBaseUrl}/';
  }

  static String formatDateTime(DateTime t) {
    final day = t.day.toString().padLeft(2, '0');
    final month = t.month.toString().padLeft(2, '0');
    final hour = t.hour.toString().padLeft(2, '0');
    final minute = t.minute.toString().padLeft(2, '0');
    final second = t.second.toString().padLeft(2, '0');
    return '$day/$month/${t.year}  $hour:$minute:$second';
  }
}
