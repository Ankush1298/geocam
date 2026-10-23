import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'exposure_meter.dart';
import 'presentation_exposure.dart';

/// One analysed preview frame. Face boxes are kept only in memory for the next exposure
/// decision; they are never saved, uploaded, or added to a GeoCam record.
@immutable
class SceneFrame {
  final LumaGrid grid;
  final FrameGeometry geometry;

  /// Detected faces in buffer space, largest first.
  final List<NormRect> faces;
  const SceneFrame(this.grid, this.geometry, this.faces);
}

/// Builds the measurement the presentation advisor uses. Marks the user placed win over automatic
/// detection, because they are the user's explicit choice.
SceneMeasurement buildMeasurement(
  SceneFrame f, {
  NormRect? presenterMark,
  NormRect? slideMark,
  bool estimateScreen = true,
}) {
  MeasuredRegion? presenter;
  if (presenterMark != null) {
    presenter = MeasuredRegion(presenterMark, f.grid.stats(presenterMark), RegionSource.markedPresenter);
  } else if (f.faces.isNotEmpty) {
    final face = f.faces.first;
    // The middle of the face box: skin, without hair or the background around the head.
    presenter = MeasuredRegion(face, f.grid.stats(face.inset(0.6)), RegionSource.detectedFace);
  }
  MeasuredRegion? slide;
  if (slideMark != null) {
    slide = MeasuredRegion(slideMark, f.grid.stats(slideMark), RegionSource.markedSlide);
  } else if (estimateScreen) {
    final s = f.grid.findBrightScreen();
    if (s != null) slide = MeasuredRegion(s.rect, f.grid.stats(s.rect), RegionSource.estimatedScreen);
  }
  return SceneMeasurement(global: f.grid.stats(), presenter: presenter, slide: slide);
}

class _GridArgs {
  final Uint8List plane;
  final int w, h, rowStride, pixelStride;
  const _GridArgs(this.plane, this.w, this.h, this.rowStride, this.pixelStride);
}

LumaGrid _buildGrid(_GridArgs a) =>
    LumaGrid.fromPlane(a.plane, srcW: a.w, srcH: a.h, rowStride: a.rowStride, pixelStride: a.pixelStride);

/// Turns camera preview frames into [SceneFrame]s. Runs entirely on the phone.
class SceneAnalyzer {
  FaceDetector? _faces;

  Future<SceneFrame?> analyze(CameraImage image, FrameGeometry geometry, {required bool detectFaces}) async {
    if (image.planes.isEmpty) return null;
    final y = image.planes.first;
    final isNv21 = image.format.group == ImageFormatGroup.nv21;
    final rowStride = y.bytesPerRow;
    final pixelStride = y.bytesPerPixel ?? 1;
    final yLength = isNv21 ? image.width * image.height : y.bytes.length;
    if (y.bytes.length < yLength || rowStride <= 0) return null;
    // Luma averaging runs on a background isolate so the preview stays smooth.
    final grid = await compute(
      _buildGrid,
      _GridArgs(Uint8List.sublistView(y.bytes, 0, yLength), image.width, image.height, rowStride, pixelStride),
    );
    final faces = detectFaces && isNv21 ? await _detectFaces(image, geometry) : const <NormRect>[];
    return SceneFrame(grid, geometry, faces);
  }

  Future<List<NormRect>> _detectFaces(CameraImage image, FrameGeometry geometry) async {
    final rotation = InputImageRotationValue.fromRawValue(geometry.rotation);
    if (rotation == null) return const [];
    _faces ??= FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        // A presenter across a classroom is small in the frame.
        minFaceSize: 0.05,
      ),
    );
    try {
      final input = InputImage.fromBytes(
        bytes: image.planes.first.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
      final found = await _faces!.processImage(input);
      // ML Kit reports boxes in the upright image.
      final (uw, uh) = geometry.uprightSize(image.width, image.height);
      final rects = found
          .map((f) => NormRect(
                (f.boundingBox.left / uw).clamp(0.0, 1.0),
                (f.boundingBox.top / uh).clamp(0.0, 1.0),
                (f.boundingBox.right / uw).clamp(0.0, 1.0),
                (f.boundingBox.bottom / uh).clamp(0.0, 1.0),
              ))
          .where((r) => !r.isEmpty)
          .map(geometry.uprightRectToBuffer)
          .toList()
        ..sort((a, b) => b.area.compareTo(a.area));
      return rects;
    } catch (_) {
      return const []; // no face result is fine: the user can mark the presenter instead
    }
  }

  Future<void> dispose() async {
    final f = _faces;
    _faces = null;
    await f?.close();
  }
}
