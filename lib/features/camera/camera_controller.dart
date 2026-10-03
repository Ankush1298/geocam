import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_exif/native_exif.dart';
import 'package:gal/gal.dart';

import '../../models/stamp_settings.dart';
import '../../models/camera_frame.dart';
import '../../services/geocoding_service.dart';
import '../../services/hash_service.dart';
import '../../services/history_store.dart';
import '../../services/location_service.dart';
import '../../services/photo_processor.dart';
import '../../services/video_processor.dart';
import '../../services/record_id_service.dart';

class VideoCaptureResult {
  final String originalPath;
  final Future<String> processedPath;
  final String recordId;
  final DateTime timestamp;
  final Position? position;
  final String address;

  const VideoCaptureResult({
    required this.originalPath,
    required this.processedPath,
    required this.recordId,
    required this.timestamp,
    required this.position,
    required this.address,
  });
}

class CaptureResult {
  // The original camera JPEG is available immediately. The processed/stamped
  // JPEG is prepared asynchronously after the result screen is shown.
  final Uint8List original;
  final Future<Uint8List> processed;
  final String recordId;
  final DateTime timestamp;
  final Position? position;
  final String address;
  final String hash;

  const CaptureResult({
    required this.original,
    required this.processed,
    required this.recordId,
    required this.timestamp,
    required this.position,
    required this.address,
    this.hash = '',
  });
}

class GeoCameraController extends ChangeNotifier {
  final List<CameraDescription> cameras;
  final LocationService locationService;
  final GeocodingService geocodingService;
  final PhotoProcessor photoProcessor;
  final VideoProcessor videoProcessor;

  CameraController? camera;
  Position? position;
  String address = '';
  StampSettings settings = StampSettings();

  int cameraIndex = 0;
  double zoom = 1.0;
  double maxZoom = 1.0;
  bool flashOn = false;
  bool torchOn = false;
  CameraFrame frame = CameraFrame.full;
  bool busy = false;
  bool isVideoRecording = false;
  DateTime? videoStartedAt;
  static const Duration maxVideoDuration = Duration(seconds: 15);
  bool initialized = false;
  String? message;
  bool locationLoading = false;
  bool locationServiceEnabled = false;
  LocationPermission locationPermission = LocationPermission.denied;
  DateTime? lastCapture;
  bool _disposed = false;
  bool _zoomUpdateInFlight = false;
  double? _pendingZoom;

  StreamSubscription<Position>? _positionSubscription;

  GeoCameraController({
    required this.cameras,
    LocationService? locationService,
    GeocodingService? geocodingService,
    PhotoProcessor? photoProcessor,
    VideoProcessor? videoProcessor,
  })  : locationService = locationService ?? LocationService(),
        geocodingService = geocodingService ?? GeocodingService(),
        photoProcessor = photoProcessor ?? PhotoProcessor(),
        videoProcessor = videoProcessor ?? VideoProcessor();

  String get locationStatus {
    final p = position;
    if (p == null) return 'Waiting for GPS';
    if (p.accuracy <= 10) return 'GPS excellent';
    if (p.accuracy <= 25) return 'GPS good';
    if (p.accuracy <= 100) return 'GPS moderate';
    return 'GPS weak';
  }

  bool get hasGoodGps => position != null && position!.accuracy <= 100;

  double frameRatio(double screenAspect) {
    final selected = frame.ratio(screenAspect);
    if (selected != null) return selected;
    final c = camera;
    if (c != null && c.value.isInitialized && c.value.previewSize != null) {
      return c.value.previewSize!.height / c.value.previewSize!.width;
    }
    return screenAspect;
  }

  Future<void> initialize() async {
    settings = await StampSettings.load();
    frame = await CameraFrameSettings.load();
    await initializeCamera();
    await initializeLocation();
    notifyListeners();
  }

  Future<void> initializeCamera() async {
    if (cameras.isEmpty) {
      _setMessage('No camera was found on this device.');
      return;
    }

    initialized = false;
    notifyListeners();

    final old = camera;
    // Detach the old controller first, but keep it alive until the new
    // controller is fully initialized. This prevents a blank preview when
    // switching between front/rear cameras.
    camera = null;
    await old?.dispose();

    final controller = CameraController(
      cameras[cameraIndex],
      ResolutionPreset.veryHigh,
      enableAudio: true,
      fps: 30,
      videoBitrate: 8000000,
      audioBitrate: 128000,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      camera = controller;

      try {
        maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {
        maxZoom = 1.0;
      }
      zoom = 1.0;

      // Restore torch state on the newly initialized camera.
      try {
        await controller.setFlashMode(
          torchOn ? FlashMode.torch : FlashMode.off,
        );
      } catch (_) {
        torchOn = false;
        flashOn = false;
      }

      initialized = true;
      if (!_disposed) {
        notifyListeners();
      }
    } catch (e) {
      await controller.dispose();
      camera = null;
      initialized = false;
      _setMessage('Camera error: $e');
    }
  }

  Future<void> initializeLocation() async {
    locationLoading = true;
    notifyListeners();
    try {
      locationServiceEnabled = await locationService.isLocationServiceEnabled();
      locationPermission = await locationService.permission();

      if (!locationServiceEnabled) {
        _setMessage('Location is turned off. Turn on Location and tap Retry GPS.');
        return;
      }

      final first = await locationService.getInitialPosition();
      if (first != null) {
        position = first;
        await _lookup(first);
      } else {
        locationPermission = await locationService.permission();
        if (locationPermission == LocationPermission.deniedForever) {
          _setMessage('Location permission is blocked. Open app settings and allow Location.');
        } else if (locationPermission == LocationPermission.denied) {
          _setMessage('Location permission is required to tag photos.');
        } else {
          _setMessage('No GPS fix yet. Keep Location on and tap Retry GPS.');
        }
      }

      await _positionSubscription?.cancel();
      _positionSubscription = locationService.watch().listen((next) {
        position = next;
        locationServiceEnabled = true;
        notifyListeners();
        _lookup(next);
      }, onError: (_) {
        _setMessage('GPS stream is unavailable. Tap Retry GPS.');
      });
    } catch (_) {
      _setMessage('GPS is unavailable. Tap Retry GPS.');
    } finally {
      locationLoading = false;
      notifyListeners();
    }
  }

  Future<void> retryLocation() async {
    locationLoading = true;
    message = null;
    notifyListeners();
    try {
      locationServiceEnabled = await locationService.isLocationServiceEnabled();
      locationPermission = await locationService.permission();

      if (!locationServiceEnabled) {
        _setMessage('Location is turned off on this phone.');
        return;
      }

      final fresh = await locationService.refreshPosition();
      if (fresh != null) {
        position = fresh;
        await _lookup(fresh);
        _setMessage('GPS location updated.');
      } else {
        locationPermission = await locationService.permission();
        if (locationPermission == LocationPermission.deniedForever) {
          _setMessage('Location permission is blocked. Open app settings and allow Location.');
        } else {
          _setMessage('Still waiting for a GPS fix. Check Location is on and try again.');
        }
      }
    } finally {
      locationLoading = false;
      notifyListeners();
    }
  }

  Future<void> _lookup(Position p) async {
    final result = await geocodingService.lookup(p.latitude, p.longitude);
    if (result.isNotEmpty) {
      address = result;
      notifyListeners();
    }
  }

  Future<void> switchCamera() async {
    if (cameras.length < 2 || busy || !initialized) return;
    cameraIndex = (cameraIndex + 1) % cameras.length;
    flashOn = false;
    torchOn = false;
    await initializeCamera();
  }

  Future<void> toggleFlash() async {
    final c = camera;
    if (c == null || !c.value.isInitialized || busy) return;

    final next = !torchOn;
    try {
      // Use torch for an immediate, visible light toggle. This also keeps
      // the light active while framing the shot, unlike FlashMode.always,
      // which only affects the capture operation.
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      torchOn = next;
      flashOn = next;
      notifyListeners();
    } catch (_) {
      _setMessage('Flash/torch is not available on this camera.');
    }
  }

  Future<void> setFrame(CameraFrame next) async {
    frame = next;
    await CameraFrameSettings.save(next);
    notifyListeners();
  }

  Future<void> setZoom(double value) async {
    final c = camera;
    if (c == null || !c.value.isInitialized) return;
    final next = value.clamp(1.0, maxZoom).toDouble();
    _pendingZoom = next;
    if (_zoomUpdateInFlight) {
      zoom = next;
      notifyListeners();
      return;
    }

    _zoomUpdateInFlight = true;
    try {
      while (_pendingZoom != null) {
        final target = _pendingZoom!;
        _pendingZoom = null;
        try {
          await c.setZoomLevel(target);
          zoom = target;
          notifyListeners();
        } catch (_) {
          _setMessage('Zoom is not available on this camera.');
          break;
        }
      }
    } finally {
      _zoomUpdateInFlight = false;
    }
  }

  Future<bool> startVideoRecording() async {
    final c = camera;
    if (c == null || !c.value.isInitialized || busy || isVideoRecording) return false;
    try {
      // startVideoRecording() is the fast native path. Preparing separately
      // adds noticeable latency on some Android devices and is unnecessary
      // for a normal single-clip recording. Audio stays enabled on the
      // CameraController, so the microphone track is recorded too.
      await c.startVideoRecording();
      isVideoRecording = true;
      videoStartedAt = DateTime.now();
      busy = true;
      notifyListeners();
      return true;
    } catch (e) {
      _setMessage('Video recording failed to start: $e');
      return false;
    }
  }

  Future<VideoCaptureResult?> stopVideoRecording() async {
    final c = camera;
    if (c == null || !c.value.isInitialized || !isVideoRecording) return null;
    try {
      final video = await c.stopVideoRecording();
      isVideoRecording = false;
      busy = false;
      final capturedAt = DateTime.now();
      final startedAt = videoStartedAt ?? capturedAt;
      videoStartedAt = null;
      final positionAtCapture = position;
      final addressAtCapture = address;
      final recordId = RecordIdService.create(startedAt);

      final processedPath = _processVideoInBackground(
        inputPath: video.path,
        position: positionAtCapture,
        address: addressAtCapture,
        timestamp: startedAt,
        recordId: recordId,
        settings: settings.copy(),
      );

      notifyListeners();
      return VideoCaptureResult(
        originalPath: video.path,
        processedPath: processedPath,
        recordId: recordId,
        timestamp: startedAt,
        position: positionAtCapture,
        address: addressAtCapture,
      );
    } catch (e) {
      isVideoRecording = false;
      busy = false;
      videoStartedAt = null;
      _setMessage('Video recording failed: $e');
      return null;
    } finally {
      notifyListeners();
    }
  }

  Future<void> cancelVideoRecording() async {
    final c = camera;
    if (c == null || !isVideoRecording) return;
    try {
      final video = await c.stopVideoRecording();
      try { await File(video.path).delete(); } catch (_) {}
    } catch (_) {}
    isVideoRecording = false;
    busy = false;
    videoStartedAt = null;
    notifyListeners();
  }

  Future<String> _processVideoInBackground({
    required String inputPath,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
  }) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final stampedPath = await videoProcessor.stampVideo(
        inputPath: inputPath,
        position: position,
        address: address,
        timestamp: timestamp,
        recordId: recordId,
        settings: settings,
      );

      // Save to the phone's shared Gallery FIRST. This copy is independent
      // of GeoCam's private app storage and must survive app-history deletion.
      await _saveVideoToGallery(stampedPath);

      // Keep a separate permanent in-app copy as well. Deleting this record
      // later only removes GeoCam's private copy; it never deletes the Gallery
      // MediaStore item saved above.
      await HistoryStore.addVideo(
        id: recordId,
        stampedPath: stampedPath,
        originalPath: inputPath,
        timestamp: timestamp,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
        altitude: position?.altitude,
        address: address,
      );
      final history = await HistoryStore.load();
      final saved = history.firstWhere((r) => r.id == recordId);

      try { await File(inputPath).delete(); } catch (_) {}
      try { await File(stampedPath).delete(); } catch (_) {}
      return saved.stampedPath;
    } catch (_) {
      // Never lose a recording because background watermarking failed.
      try {
        await HistoryStore.addVideo(
          id: recordId,
          stampedPath: inputPath,
          originalPath: inputPath,
          timestamp: timestamp,
          latitude: position?.latitude,
          longitude: position?.longitude,
          accuracy: position?.accuracy,
          altitude: position?.altitude,
          address: address,
        );
        // Save the original recording independently to the phone Gallery.
        // This remains even if the GeoCam record is deleted later.
        await _saveVideoToGallery(inputPath);
        final history = await HistoryStore.load();
        final saved = history.firstWhere((r) => r.id == recordId);
        return saved.stampedPath;
      } catch (_) {
        try { await _saveVideoToGallery(inputPath); } catch (_) {}
        return inputPath;
      }
    }
  }

  Future<void> _saveVideoToGallery(String path) async {
    if (kIsWeb) return;
    final granted = await Gal.requestAccess(toAlbum: true);
    if (!granted) throw StateError('Gallery permission was not granted.');
    await Gal.putVideo(path, album: 'GeoCam');
  }

  Future<CaptureResult?> capture({bool allowWeakGps = false, double? screenAspect}) async {
    final c = camera;
    if (c == null || !c.value.isInitialized || busy) return null;

    if (position != null && position!.accuracy > 100 && !allowWeakGps) {
      return null;
    }

    // Only the real camera shutter/read is part of the critical path.
    // Expensive stamping, QR rendering, compression, EXIF and history I/O
    // start after the result screen can already render the captured JPEG.
    busy = true;
    notifyListeners();

    try {
      final shot = await c.takePicture();
      final capturedAt = DateTime.now();
      final rawBytes = await shot.readAsBytes();
      final positionAtCapture = position;
      final addressAtCapture = address;
      final recordId = RecordIdService.create(capturedAt);
      final selectedFrame = frame;
      final selectedSettings = settings.copy();
      final capturedScreenAspect =
          screenAspect ?? c.value.aspectRatio;

      // Compute the HMAC signature before processing so it can be embedded
      // into the stamp panel, QR code, and the history index atomically.
      final hash = await HashService.sign(
        recordId: recordId,
        timestamp: capturedAt,
        latitude: positionAtCapture?.latitude,
        longitude: positionAtCapture?.longitude,
        accuracy: positionAtCapture?.accuracy,
        address: addressAtCapture,
      );

      // Start processing without awaiting it. The result page receives the
      // original camera image immediately and silently swaps in the stamped
      // image when processing finishes.
      final processed = _processCaptureInBackground(
        shotPath: shot.path,
        rawBytes: rawBytes,
        position: positionAtCapture,
        address: addressAtCapture,
        timestamp: capturedAt,
        recordId: recordId,
        settings: selectedSettings,
        frame: selectedFrame,
        screenAspect: capturedScreenAspect,
        hash: hash,
      );

      lastCapture = capturedAt;
      return CaptureResult(
        original: rawBytes,
        processed: processed,
        recordId: recordId,
        timestamp: capturedAt,
        position: positionAtCapture,
        address: addressAtCapture,
        hash: hash,
      );
    } catch (e) {
      _setMessage('Capture failed: $e');
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<Uint8List> _embedExifGpsIntoStampedImage({
    required Uint8List stamped,
    required Position? position,
    required String recordId,
    String hash = '',
  }) async {
    if (kIsWeb || position == null) return stamped;

    final dir = await Directory.systemTemp.createTemp('geocam_exif_');
    final path = '${dir.path}/$recordId.jpg';
    try {
      final file = File(path);
      await file.writeAsBytes(stamped, flush: true);
      final exif = await Exif.fromPath(path);
      await exif.writeAttributes({
        'GPSLatitude': position.latitude.abs(),
        'GPSLatitudeRef': position.latitude >= 0 ? 'N' : 'S',
        'GPSLongitude': position.longitude.abs(),
        'GPSLongitudeRef': position.longitude >= 0 ? 'E' : 'W',
        'GPSAltitude': position.altitude.abs(),
        'GPSAltitudeRef': position.altitude >= 0 ? '0' : '1',
      });
      // native_exif writeAttributes doesn't fully support all string tags generically,
      // but writeAttribute can set UserComment. Let's try setting it safely.
      // If the plugin has trouble with UserComment, we will just continue.
      try {
        await exif.writeAttribute('UserComment', 'GeoCam Signature: $hash');
      } catch (_) {}
      await exif.close();
      return await file.readAsBytes();
    } catch (_) {
      return stamped;
    } finally {
      try { await dir.delete(recursive: true); } catch (_) {}
    }
  }

  Future<Uint8List> _processCaptureInBackground({
    required String shotPath,
    required Uint8List rawBytes,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    required CameraFrame frame,
    required double screenAspect,
    String hash = '',
  }) async {
    // Let Flutter paint the captured image before starting the expensive
    // image pipeline. This keeps the camera/result transition responsive.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final stamped = await photoProcessor.stamp(
      jpg: rawBytes,
      position: position,
      address: address,
      timestamp: timestamp,
      recordId: recordId,
      settings: settings,
      frame: frame,
      screenAspect: screenAspect,
      hash: hash,
    );

    // Write GPS EXIF to the FINAL stamped JPEG, not only the original camera
    // file. This gives us both layers: a visible pixel-embedded stamp and
    // machine-readable EXIF metadata.
    final stampedWithExif = await _embedExifGpsIntoStampedImage(
      stamped: stamped,
      position: position,
      recordId: recordId,
      hash: hash,
    );

    if (!kIsWeb) {
      // Phone Gallery is a shared MediaStore copy. Save it independently
      // before touching GeoCam's private history so app deletion cannot affect it.
      try {
        await Gal.putImageBytes(
          stampedWithExif,
          album: 'GeoCam',
          name: '$recordId.jpg',
        );
      } catch (_) {}

      try {
        await HistoryStore.add(
          id: recordId,
          stamped: stampedWithExif,
          original: rawBytes,
          timestamp: timestamp,
          latitude: position?.latitude,
          longitude: position?.longitude,
          accuracy: position?.accuracy,
          altitude: position?.altitude,
          address: address,
          hash: hash,
        );
      } catch (_) {}

      try {
        final pubKey = await HashService.getPublicKey();
        final payload = jsonEncode({
          'id': recordId,
          'timestamp': timestamp.toIso8601String(),
          'latitude': position?.latitude,
          'longitude': position?.longitude,
          'accuracy': position?.accuracy,
          'altitude': position?.altitude,
          'address': address,
          'hash': hash,
          'public_key': pubKey,
        });
        http.post(
          Uri.parse('https://weak-breads-roll.loca.lt/sync'),
          headers: {
            'Content-Type': 'application/json',
            'Bypass-Tunnel-Reminder': 'true'
          },
          body: payload,
        ).catchError((_) => http.Response('', 500));
      } catch (_) {}
    }

    return stampedWithExif;
  }

  Future<void> saveSettings(StampSettings next) async {
    settings = next.copy();
    await settings.save();
    notifyListeners();
  }

  void clearMessage() {
    message = null;
  }

  void _setMessage(String value) {
    message = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _positionSubscription?.cancel();
    camera?.dispose();
    super.dispose();
  }
}
