import 'dart:async';
import 'dart:io';
import 'dart:math' show max;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation, PlatformException;
import 'package:geolocator/geolocator.dart';
import 'package:native_exif/native_exif.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/stamp_settings.dart';
import '../../models/camera_frame.dart';
import '../../models/camera_tuning.dart';
import '../../services/camera_tuning_bridge.dart';
import '../../services/exposure_meter.dart';
import '../../services/presentation_exposure.dart';
import '../../services/scene_analyzer.dart';
import '../../services/geocoding_service.dart';
import '../../services/hash_service.dart';
import '../../services/history_store.dart';
import '../../services/location_service.dart';
import '../../services/photo_processor.dart';
import '../../services/video_processor.dart';
import '../../services/fingerprint_service.dart';
import '../../services/record_id_service.dart';
import '../../services/gps_clock.dart';
import '../../services/sync_service.dart';

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
  final String signature;
  /// Front-camera raw bytes are mirrored until processed, so the result
  /// screen must wait for [processed] instead of flashing [original].
  final bool isFrontCamera;

  const CaptureResult({
    required this.original,
    required this.processed,
    required this.recordId,
    required this.timestamp,
    required this.position,
    required this.address,
    this.signature = '',
    this.isFrontCamera = false,
  });
}

/// State of the on-screen focus/metering indicator after a tap.
enum FocusMarkerState { working, focused, notConfirmed, metered, failed }

@immutable
class FocusMarker {
  final double x, y; // 0..1 over the preview as displayed
  final FocusMarkerState state;
  final bool locked;
  final bool focus;
  final bool meter;
  const FocusMarker(this.x, this.y, this.state, {this.locked = false, this.focus = true, this.meter = true});
  FocusMarker withState(FocusMarkerState s) => FocusMarker(x, y, s, locked: locked, focus: focus, meter: meter);
}

/// What the next tap on the preview marks in Presentation Mode.
enum MarkTarget { none, presenter, slide }

/// A presenter/slide mark: buffer space for measuring, display space for drawing.
@immutable
class SceneMark {
  final NormRect buffer;
  final NormRect display;
  const SceneMark(this.buffer, this.display);
}

/// One step of the camera control check (the proof that the native bridge drives the plugin's camera).
@immutable
class ControlCheckStep {
  final String name;
  final bool? passed; // null = skipped
  final String detail;
  const ControlCheckStep(this.name, this.passed, this.detail);
}

/// Thrown inside the controller when an operation belongs to a camera session that has ended, or is
/// an automatic change that a capture has made obsolete. Never shown to the user.
class _StaleOperation implements Exception {
  const _StaleOperation();
}

/// One opened camera. A new session is created for every camera (re)initialisation; the old one is
/// closed synchronously before anything is awaited, so async work started for it can tell.
class _CameraSession {
  final int generation;
  final String cameraId;
  final CameraController controller;
  bool closed = false;

  /// What this camera last confirmed (manual overrides and exposure compensation).
  CameraTuning applied = CameraTuning.automatic;

  /// Set once any override or exposure change was sent, so the camera is reset when released:
  /// CameraX keeps Camera2 overrides on the physical camera after its use cases are unbound.
  bool touched = false;

  _CameraSession(this.generation, this.cameraId, this.controller);
}

/// A request for the settings worker. Automatic requests (from preview analysis) carry the capture
/// epoch they were computed in and are dropped if a capture has started since.
class _TuningRequest {
  final CameraTuning target;
  final _CameraSession session;
  final int? automaticEpoch;
  final bool resend; // camera state unknown (e.g. after reopening): send everything
  final bool quiet;
  const _TuningRequest(this.target, this.session, {this.automaticEpoch, this.resend = false, this.quiet = false});
  bool get automatic => automaticEpoch != null;
  _TuningRequest withResend() => _TuningRequest(target, session, automaticEpoch: automaticEpoch, resend: true, quiet: quiet);
}

/// One preview analysis. Cancelling marks it so its result is discarded; the frame read, isolate and
/// ML Kit work already started cannot be stopped and simply finish unused.
class _AnalysisRun {
  final _CameraSession session;
  final int captureEpoch;
  bool cancelled = false;
  int ticksWaited = 0;
  _AnalysisRun(this.session, this.captureEpoch);
}

/// The single preview frame an analysis run is waiting for; [abort] releases the waiter at once.
class _FrameGrab {
  final CameraController controller;
  final Completer<CameraImage?> _done = Completer<CameraImage?>();
  _FrameGrab(this.controller);
  void deliver(CameraImage image) {
    if (!_done.isCompleted) _done.complete(image);
  }

  void abort() {
    if (!_done.isCompleted) _done.complete(null);
  }

  Future<CameraImage?> get result => _done.future;
}

class GeoCameraController extends ChangeNotifier {
  final List<CameraDescription> cameras;
  final LocationService locationService;
  final GeocodingService geocodingService;
  final PhotoProcessor photoProcessor;
  final VideoProcessor videoProcessor;
  final CameraTuningBridge tuningBridge;

  // Camera controls (exposure, focus, white balance). Always start automatic.
  CameraCapabilities capabilities = CameraCapabilities.none;
  CameraTuning tuning = CameraTuning.automatic;
  FocusMarker? focusMarker;
  Timer? _focusMarkerTimer;

  // Presentation Mode and exposure guidance (photo mode only).
  bool presentationMode = false;
  PresentationProfile presentationProfile = PresentationProfile.balanced;
  bool exposureWarnings = true;
  bool videoModeActive = false;
  List<SceneWarning> sceneWarnings = const [];
  SceneMeasurement? lastMeasurement;
  ExposureAdvice? lastAdvice;
  FrameGeometry? lastGeometry;
  SceneMark? presenterMark;
  SceneMark? slideMark;
  MarkTarget armedMark = MarkTarget.none;
  bool _appActive = true;
  bool _covered = false;
  Timer? _analysisTimer;
  LumaGrid? _lastGrid;
  final SceneAnalyzer _sceneAnalyzer;
  final CameraController Function(CameraDescription description) _cameraFactory;
  final Duration _analysisInterval;
  static const _profileKey = 'presentation_profile';
  static const _warningsKey = 'exposure_warnings';

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
  StreamSubscription<Position>? _gpsClockSubscription;
  final GpsClockTracker gpsClock = GpsClockTracker();

  GeoCameraController({
    required this.cameras,
    LocationService? locationService,
    GeocodingService? geocodingService,
    PhotoProcessor? photoProcessor,
    VideoProcessor? videoProcessor,
    CameraTuningBridge? tuningBridge,
    SceneAnalyzer? sceneAnalyzer,
    @visibleForTesting CameraController Function(CameraDescription description)? cameraFactory,
    @visibleForTesting Duration analysisInterval = const Duration(milliseconds: 500),
  })  : locationService = locationService ?? LocationService(),
        geocodingService = geocodingService ?? GeocodingService(),
        photoProcessor = photoProcessor ?? PhotoProcessor(),
        videoProcessor = videoProcessor ?? VideoProcessor(),
        tuningBridge = tuningBridge ?? CameraTuningBridge(),
        _sceneAnalyzer = sceneAnalyzer ?? SceneAnalyzer(),
        _cameraFactory = cameraFactory ?? _defaultCamera,
        _analysisInterval = analysisInterval;

  static CameraController _defaultCamera(CameraDescription description) => CameraController(
        description,
        ResolutionPreset.veryHigh,
        enableAudio: true,
        fps: 30,
        videoBitrate: 8000000,
        audioBitrate: 128000,
        // With the CameraX implementation this only sets the format of preview frames streamed to
        // Dart for exposure analysis (NV21 is what ML Kit needs). Photos are always JPEG from
        // ImageCapture and videos are unaffected.
        imageFormatGroup: ImageFormatGroup.nv21,
      );

  /// Label from the horizontal accuracy (metres, 68% confidence radius) that the
  /// device reports. Thresholds: <=10 excellent, <=25 good, <=100 moderate, else weak.
  /// This describes how precise the reading claims to be; it does not prove the
  /// location is real (mock locations and spoofing are not detected).
  static String gpsQualityLabel(double? accuracyMeters) {
    if (accuracyMeters == null) return 'Waiting for GPS';
    final m = accuracyMeters.round();
    if (accuracyMeters <= 10) return 'GPS excellent (±$m m)';
    if (accuracyMeters <= 25) return 'GPS good (±$m m)';
    if (accuracyMeters <= 100) return 'GPS moderate (±$m m)';
    return 'GPS weak (±$m m)';
  }

  String get locationStatus {
    if (position == null && !locationLoading) {
      if (!locationServiceEnabled) return 'Location is off';
      if (locationPermission == LocationPermission.denied ||
          locationPermission == LocationPermission.deniedForever) {
        return 'Location permission needed';
      }
    }
    return gpsQualityLabel(position?.accuracy);
  }

  bool get hasGoodGps => position != null && position!.accuracy <= 100;

  bool get isFrontCamera =>
      cameraIndex < cameras.length &&
      cameras[cameraIndex].lensDirection == CameraLensDirection.front;

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
    unawaited(SyncService.syncPending());
    SyncService.startAutoRetry();
    frame = await CameraFrameSettings.load();
    try {
      final p = await SharedPreferences.getInstance();
      presentationProfile = PresentationProfile.values.firstWhere(
        (v) => v.name == p.getString(_profileKey),
        orElse: () => PresentationProfile.balanced,
      );
      exposureWarnings = p.getBool(_warningsKey) ?? true;
    } catch (_) {}
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
    // End the old session before anything is awaited: from here on, nothing started for the old
    // camera can change settings, publish analysis results or touch the UI.
    final oldSession = _closeSession();
    _stopAnalysisTimer();
    _resetTuningState();
    _notify();

    final old = camera;
    // Detach the old controller first, but keep it alive until the new
    // controller is fully initialized. This prevents a blank preview when
    // switching between front/rear cameras.
    camera = null;
    if (old != null) await _releaseCamera(old, oldSession);

    final controller = _cameraFactory(cameras[cameraIndex]);

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
        final session = _CameraSession(++_generationCounter, cameras[cameraIndex].name, controller);
        _session = session;
        notifyListeners();
        unawaited(_prepareTuning(session));
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

      await _gpsClockSubscription?.cancel();
      gpsClock.reset(); // a restarted stream must not be linked to fixes from before the restart
      _gpsClockSubscription = locationService.gpsTimeStream().listen(
        gpsClock.onFix,
        onError: (_) {}, // no satellite fix is fine: the capture just has no GPS time reference
      );
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
    _beginProtected();
    try {
      // The camera plugin cannot start recording while preview frames stream to Dart. Close only the
      // frame stream (one platform call); analysis work already past the frame read finishes unused.
      _cancelAnalysisRun();
      await _closeFrameStream(c);
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
    } finally {
      _endProtected();
      _updateAnalysisTimer();
    }
  }

  Future<VideoCaptureResult?> stopVideoRecording() async {
    final c = camera;
    if (c == null || !c.value.isInitialized || !isVideoRecording) return null;
    _beginProtected();
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
        isFrontCamera: isFrontCamera,
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
      _endProtected();
      _updateAnalysisTimer();
      _notify();
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
    _updateAnalysisTimer();
    _notify();
  }

  Future<String> _processVideoInBackground({
    required String inputPath,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    required bool isFrontCamera,
  }) async {
    String finalPath = inputPath;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      try {
        finalPath = await videoProcessor.stampVideo(
          inputPath: inputPath, position: position, address: address,
          timestamp: timestamp, recordId: recordId, settings: settings,
          isFrontCamera: isFrontCamera,
        );
      } catch (_) { finalPath = inputPath; }

      final mediaSha256 = await HashService.sha256File(finalPath);
      final publicKey = await HashService.getPublicKey();
      final signature = await HashService.sign(
        recordId: recordId, mediaType: 'video', timestamp: timestamp,
        latitude: position?.latitude, longitude: position?.longitude,
        accuracy: position?.accuracy, altitude: position?.altitude,
        address: address, mediaSha256: mediaSha256,
      );
      await _saveVideoToGallery(finalPath);
      await HistoryStore.addVideo(
        id: recordId, stampedPath: finalPath, originalPath: inputPath,
        timestamp: timestamp, latitude: position?.latitude, longitude: position?.longitude,
        accuracy: position?.accuracy, altitude: position?.altitude, address: address,
        signature: signature, mediaSha256: mediaSha256, publicKey: publicKey,
      );
      final saved = (await HistoryStore.load()).firstWhere((r) => r.id == recordId);
      unawaited(SyncService.sync(saved));
      // HistoryStore now owns its own copy, so the camera/FFmpeg temporary
      // files can always be removed after the record is committed.
      if (finalPath != inputPath) { try { await File(finalPath).delete(); } catch (_) {} }
      try { await File(inputPath).delete(); } catch (_) {}
      return saved.stampedPath;
    } catch (_) {
      try { await _saveVideoToGallery(finalPath); } catch (_) {}
      try {
        final mediaSha256 = await HashService.sha256File(finalPath);
        final publicKey = await HashService.getPublicKey();
        final signature = await HashService.sign(
          recordId: recordId, mediaType: 'video', timestamp: timestamp,
          latitude: position?.latitude, longitude: position?.longitude,
          accuracy: position?.accuracy, altitude: position?.altitude,
          address: address, mediaSha256: mediaSha256,
        );
        await HistoryStore.addVideo(
          id: recordId, stampedPath: finalPath, originalPath: inputPath,
          timestamp: timestamp, latitude: position?.latitude, longitude: position?.longitude,
          accuracy: position?.accuracy, altitude: position?.altitude, address: address,
          signature: signature, mediaSha256: mediaSha256, publicKey: publicKey,
        );
        final saved = (await HistoryStore.load()).firstWhere((r) => r.id == recordId);
        unawaited(SyncService.sync(saved));
        if (finalPath != inputPath) { try { await File(finalPath).delete(); } catch (_) {} }
        try { await File(inputPath).delete(); } catch (_) {}
        return saved.stampedPath;
      } catch (_) { return inputPath; }
    }
  }

  Future<CaptureResult?> capture({bool allowWeakGps = false, double? screenAspect}) async {
    final c = camera;
    if (c == null || !c.value.isInitialized || busy) return null;
    if (position != null && position!.accuracy > 100 && !allowWeakGps) return null;

    busy = true;
    notifyListeners();
    // Protected until the capture returns: no new preview analysis starts, results of analysis that
    // is already running are discarded, and no automatic exposure change is sent. Nothing here
    // waits for that analysis (CameraX captures alongside frame analysis), so the shutter is not
    // delayed by it.
    _beginProtected();
    try {
      final shot = await c.takePicture();
      final capturedAt = DateTime.now().toUtc();
      final rawBytes = await shot.readAsBytes();
      final front = isFrontCamera;
      final positionAtCapture = position;
      final addressAtCapture = address;
      final recordId = RecordIdService.create(capturedAt);
      final selectedFrame = frame;
      final selectedSettings = settings.copy();
      final capturedScreenAspect = screenAspect ?? c.value.aspectRatio;
      final processed = _processCaptureInBackground(
        shotPath: shot.path, rawBytes: rawBytes, position: positionAtCapture,
        address: addressAtCapture, timestamp: capturedAt, recordId: recordId,
        settings: selectedSettings, frame: selectedFrame, screenAspect: capturedScreenAspect,
        isFrontCamera: front, gpsClockOffsetMs: gpsClock.offsetFor(capturedAt),
      );
      lastCapture = capturedAt;
      return CaptureResult(
        original: rawBytes, processed: processed, recordId: recordId,
        timestamp: capturedAt, position: positionAtCapture, address: addressAtCapture,
        isFrontCamera: front,
      );
    } catch (e) {
      _setMessage('Capture failed: $e');
      return null;
    } finally {
      _endProtected();
      busy = false;
      _notify();
    }
  }

  Future<Uint8List> _embedExifGpsIntoStampedImage({
    required Uint8List stamped,
    required Position? position,
    required String recordId,
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
    required bool isFrontCamera,
    int? gpsClockOffsetMs,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final stamped = await photoProcessor.stamp(
      jpg: rawBytes, position: position, address: address, timestamp: timestamp,
      recordId: recordId, settings: settings, frame: frame, screenAspect: screenAspect,
      isFrontCamera: isFrontCamera,
    );
    final stampedWithExif = await _embedExifGpsIntoStampedImage(
      stamped: stamped, position: position, recordId: recordId,
    );

    if (!kIsWeb) {
      final mediaSha256 = await HashService.sha256Bytes(stampedWithExif);
      final publicKey = await HashService.getPublicKey();

      // Compute region fingerprint manifest (Layer B)
      final fpManifest = await FingerprintService.generate(stampedWithExif, gpsClockOffsetMs: gpsClockOffsetMs);
      final imageDimensions = fpManifest != null
          ? '${fpManifest.imageWidth}x${fpManifest.imageHeight}'
          : null;
      final fpVersion = fpManifest?.fpVersion ?? 0;
      final fpSha256 = fpManifest?.sha256Digest;
      final regionFingerprints = fpManifest?.toCanonicalJson();

      final signature = await HashService.sign(
        proto: 3,
        recordId: recordId,
        mediaType: 'photo',
        timestamp: timestamp,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
        altitude: position?.altitude,
        address: address,
        mediaSha256: mediaSha256,
        imageDimensions: imageDimensions,
        fpVersion: fpVersion,
        fpSha256: fpSha256,
      );
      try { await Gal.putImageBytes(stampedWithExif, album: 'GeoCam', name: '$recordId.jpg'); } catch (_) {}
      try {
        await HistoryStore.add(
          protocolVersion: 3,
          id: recordId,
          stamped: stampedWithExif,
          original: rawBytes,
          timestamp: timestamp,
          latitude: position?.latitude,
          longitude: position?.longitude,
          accuracy: position?.accuracy,
          altitude: position?.altitude,
          address: address,
          signature: signature,
          mediaSha256: mediaSha256,
          publicKey: publicKey,
          imageDimensions: imageDimensions,
          fpVersion: fpVersion,
          fpSha256: fpSha256,
          regionFingerprints: regionFingerprints,
        );
        final saved = (await HistoryStore.load()).firstWhere((r) => r.id == recordId);
        unawaited(SyncService.sync(saved));
      } catch (_) {}
    }
    try { await File(shotPath).delete(); } catch (_) {}
    return stampedWithExif;
  }

  // ======================================================================== camera controls
  //
  // Concurrency model (everything runs on the UI isolate; nothing blocks it):
  //
  // * Camera session. Every opened camera gets a new [_CameraSession]. Switching cameras,
  //   re-initialising or disposing closes the old session synchronously, before anything is
  //   awaited. All camera work goes through [_bridge], which checks the session before each call
  //   and again after it returns; stale work raises [_StaleOperation] and stops without touching
  //   the camera or the UI.
  // * Protected operations. Photo capture, starting/stopping video and the control check bump
  //   [_captureEpoch]. Automatic exposure changes computed before that are dropped; user changes
  //   wait (asynchronously) until the protected operation ends. A capture itself never waits for
  //   analysis or settings work.
  // * Settings worker. Requests are applied one at a time, latest request wins, so two changes can
  //   never interleave on the camera.
  // * Preview analysis. At most one [_AnalysisRun] owns the analysis slot. Its result is published
  //   only if the run is still the current one, for the same session, and no capture started
  //   since. A run that has not finished after [_analysisRunTicks] ticks is abandoned, so analysis
  //   can never stay stuck.

  static int _generationCounter = 0;
  _CameraSession? _session;
  int _captureEpoch = 0;
  int _protectedOps = 0;
  Completer<void>? _captureIdleCompleter;
  _TuningRequest? _pendingTuning;
  bool _tuningDraining = false;
  Future<void> _tuningDone = Future<void>.value();
  _AnalysisRun? _analysisRun;
  _FrameGrab? _frameGrab;
  int _runsSinceAutoEv = 0;
  CameraTuning? _resumeTuningAfterCover;

  /// Ticks a run may take before it is abandoned (frame read + luma isolate + face detection).
  static const _analysisRunTicks = 8;

  /// Completed analyses to skip after an automatic exposure change, so the next decision is based
  /// on a frame taken after auto-exposure has adjusted.
  static const _settleRuns = 2;

  bool _isLive(_CameraSession s) => !_disposed && !s.closed && identical(_session, s);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Ends the current session (if any) and returns it. Pending work for it becomes stale.
  _CameraSession? _closeSession() {
    final s = _session;
    _session = null;
    s?.closed = true;
    _pendingTuning = null;
    _cancelAnalysisRun();
    return s;
  }

  void _resetTuningState() {
    capabilities = CameraCapabilities.none;
    tuning = CameraTuning.automatic;
    _focusMarkerTimer?.cancel();
    focusMarker = null;
    presenterMark = null;
    slideMark = null;
    armedMark = MarkTarget.none;
    sceneWarnings = const [];
    lastMeasurement = null;
    lastAdvice = null;
    lastGeometry = null;
    _lastGrid = null;
    _runsSinceAutoEv = _settleRuns;
    _resumeTuningAfterCover = null;
  }

  /// Leaves [old] clean before it is disposed: closes a frame stream this controller opened and
  /// removes Camera2 overrides / exposure compensation, which CameraX keeps on the physical camera
  /// after its use cases are unbound (they would otherwise affect the next user of that camera,
  /// such as the QR scanner). The clean-up is bounded so a stuck call cannot block the switch.
  Future<void> _releaseCamera(CameraController old, _CameraSession? s) async {
    await _closeFrameStream(old);
    if (s != null && s.touched && tuningBridge.available) {
      try {
        await Future.wait([
          tuningBridge.applyOverrides(s.cameraId, const {}),
          tuningBridge.setExposureIndex(s.cameraId, 0),
        ]).timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    try {
      await old.dispose();
    } catch (_) {}
  }

  /// Runs a native-bridge call for session [s]. Checks the session (and, for automatic changes,
  /// that no capture has started since [automaticEpoch]) before every attempt and after the call
  /// returns. User changes pass [waitForCapture] and wait for a capture in progress to finish.
  Future<T> _bridge<T>(
    _CameraSession s,
    Future<T> Function(String cameraId) op, {
    int? automaticEpoch,
    bool waitForCapture = false,
  }) async {
    for (var attempt = 0;; attempt++) {
      if (waitForCapture) await _captureIdle();
      if (!_isLive(s)) throw const _StaleOperation();
      if (automaticEpoch != null && (automaticEpoch != _captureEpoch || _protectedOps > 0 || isVideoRecording)) {
        throw const _StaleOperation();
      }
      try {
        final result = await op(s.cameraId);
        if (!_isLive(s)) throw const _StaleOperation();
        return result;
      } on PlatformException catch (e) {
        // Right after the plugin opens a camera, CameraX can still report it as opening.
        if (e.code != 'camera_not_open' || attempt >= 6) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  // ------------------------------------------------------------------ protected operations

  void _beginProtected() {
    _protectedOps++;
    _captureEpoch++;
  }

  void _endProtected() {
    if (_protectedOps > 0) _protectedOps--;
    if (_protectedOps == 0) {
      final c = _captureIdleCompleter;
      _captureIdleCompleter = null;
      c?.complete();
    }
  }

  Future<void> _captureIdle() async {
    while (_protectedOps > 0 && !_disposed) {
      await (_captureIdleCompleter ??= Completer<void>()).future;
    }
  }

  // ------------------------------------------------------------------ settings

  Future<void> _prepareTuning(_CameraSession s) async {
    if (!tuningBridge.available) return;
    try {
      final caps = await tuningBridge.capabilities(s.cameraId);
      if (!_isLive(s)) return;
      // Start automatic even if CameraX kept overrides on this physical camera from an earlier
      // session. Controls appear only after this, so no user change can race with it.
      await _bridge(s, (id) => tuningBridge.applyOverrides(id, const {}));
      if (caps.exposureCompensation) await _bridge(s, (id) => tuningBridge.setExposureIndex(id, 0));
      s.applied = CameraTuning.automatic;
      capabilities = caps;
    } on _StaleOperation {
      return;
    } catch (_) {
      // Controls stay hidden; capture is unaffected.
      if (_isLive(s)) capabilities = CameraCapabilities.none;
    }
    if (_isLive(s)) {
      _updateAnalysisTimer();
      _notify();
    }
  }

  /// Applies [next] (clamped to what the camera reports) to the current camera. Changes made while
  /// a photo is being taken are applied right after it. On failure the camera's last confirmed
  /// settings are restored and the user is told.
  Future<void> applyTuning(CameraTuning next, {bool quiet = false}) {
    final s = _session;
    if (!initialized || s == null) return Future<void>.value();
    return _submitTuning(_TuningRequest(next.supportedBy(capabilities), s, quiet: quiet));
  }

  Future<void> _submitTuning(_TuningRequest r) {
    final pending = _pendingTuning;
    // Never let an automatic change replace a user change that has not been sent yet.
    if (r.automatic && pending != null && !pending.automatic) return _tuningDone;
    _pendingTuning =
        pending != null && pending.resend && !r.resend && identical(pending.session, r.session) ? r.withResend() : r;
    if (_isLive(r.session)) {
      tuning = r.target;
      _notify();
    }
    if (!_tuningDraining) {
      _tuningDraining = true;
      _tuningDone = _drainTuning();
    }
    return _tuningDone;
  }

  Future<void> _drainTuning() async {
    try {
      while (true) {
        final r = _pendingTuning;
        if (r == null) return;
        _pendingTuning = null;
        await _applyTuningRequest(r);
      }
    } finally {
      _tuningDraining = false; // set in the same step that found the queue empty: no lost request
    }
  }

  Future<void> _applyTuningRequest(_TuningRequest r) async {
    final s = r.session;
    final wait = !r.automatic;
    try {
      final base = r.resend ? null : s.applied;
      final overrides = r.target.nativeOverrides();
      if (base == null || !mapEquals(base.nativeOverrides(), overrides)) {
        await _bridge(s, (id) {
          s.touched = true;
          return tuningBridge.applyOverrides(id, overrides);
        }, automaticEpoch: r.automaticEpoch, waitForCapture: wait);
        s.applied = r.target.copyWith(evIndex: s.applied.evIndex);
      }
      if (capabilities.exposureCompensation && (base == null || base.evIndex != r.target.evIndex)) {
        final index = await _bridge(s, (id) {
          s.touched = true;
          return tuningBridge.setExposureIndex(id, r.target.evIndex);
        }, automaticEpoch: r.automaticEpoch, waitForCapture: wait);
        if (r.automatic) _runsSinceAutoEv = 0;
        s.applied = s.applied.copyWith(evIndex: index);
      }
      s.applied = r.target.copyWith(evIndex: s.applied.evIndex);
      if (_isLive(s) && _pendingTuning == null) tuning = s.applied;
    } on _StaleOperation {
      // Old camera, closed page, or an automatic change that a capture made obsolete.
      if (_isLive(s) && _pendingTuning == null) tuning = s.applied;
    } catch (e) {
      if (!_isLive(s)) return; // errors from an old camera never touch the current UI
      try {
        await _bridge(s, (id) => tuningBridge.applyOverrides(id, s.applied.nativeOverrides()), waitForCapture: true);
      } catch (_) {}
      if (!_isLive(s)) return;
      if (_pendingTuning == null) tuning = s.applied;
      if (!r.quiet && !r.automatic) _setMessage('Camera setting was not applied: ${_errorText(e)}');
    }
    _notify();
  }

  Future<void> resetAllTuning() async {
    await cancelFocusLock();
    await applyTuning(CameraTuning.automatic);
  }

  /// Manual ISO/shutter is offered for photos only, so a video never records with a fixed
  /// exposure the user may have forgotten about.
  Future<void> setVideoMode(bool video) async {
    videoModeActive = video;
    if (video) {
      armedMark = MarkTarget.none;
      if (tuning.exposure == ExposureControl.manual) {
        await applyTuning(tuning.resetExposure());
        _setMessage('Manual exposure is for photos; video uses automatic exposure.');
      }
    }
    _updateAnalysisTimer();
    _notify();
  }

  // ------------------------------------------------------------------ tap to focus / meter

  /// A tap on the preview at ([x], [y]) in 0..1 display coordinates. Long-press keeps focus and
  /// metering on that point until the next tap or a reset.
  Future<void> onPreviewTap(double x, double y, {bool lock = false}) async {
    final s = _session;
    if (!initialized || s == null || busy) return;
    if (armedMark != MarkTarget.none) {
      _placeMark(armedMark, x, y);
      return;
    }
    final canFocus = capabilities.tapToFocus && tuning.focus == FocusControl.auto;
    // In Presentation Mode the profile owns exposure, so a tap only focuses.
    final canMeter = capabilities.tapToMeter &&
        tuning.exposure == ExposureControl.auto &&
        !tuning.aeLocked &&
        !presentationMode;
    if (!canFocus && !canMeter) {
      if (capabilities != CameraCapabilities.none) {
        _setMessage(tuning.focus == FocusControl.manual
            ? 'Manual focus is on. Switch focus back to Auto to tap-focus.'
            : 'This camera does not support tap-to-focus.');
      }
      return;
    }
    _focusMarkerTimer?.cancel();
    final marker = FocusMarker(x, y, FocusMarkerState.working, locked: lock, focus: canFocus, meter: canMeter);
    focusMarker = marker;
    _notify();
    try {
      final r = await _bridge(s, (id) => tuningBridge.focusAndMeter(id, x: x, y: y, af: canFocus, ae: canMeter, lock: lock));
      if (!identical(focusMarker, marker)) return; // a newer tap replaced this one
      final state = r.cancelled
          ? FocusMarkerState.notConfirmed
          : !r.focusRequested
              ? FocusMarkerState.metered
              : r.focusSuccessful
                  ? FocusMarkerState.focused
                  : FocusMarkerState.notConfirmed;
      focusMarker = marker.withState(state);
    } on _StaleOperation {
      return; // camera switched or page closed: nothing to show
    } catch (e) {
      if (!_isLive(s) || !identical(focusMarker, marker)) return;
      focusMarker = marker.withState(FocusMarkerState.failed);
      _setMessage('Tap-to-focus failed: ${_errorText(e)}');
    }
    _notify();
    if (!lock) {
      final shown = focusMarker;
      _focusMarkerTimer = Timer(const Duration(milliseconds: 2500), () {
        if (identical(focusMarker, shown)) {
          focusMarker = null;
          _notify();
        }
      });
    }
  }

  Future<void> cancelFocusLock() async {
    _focusMarkerTimer?.cancel();
    final hadMarker = focusMarker != null;
    focusMarker = null;
    if (hadMarker) _notify();
    final s = _session;
    if (s == null || !capabilities.tapToMeter && !capabilities.tapToFocus) return;
    try {
      await _bridge(s, (id) => tuningBridge.cancelFocusAndMeter(id));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ Presentation Mode

  Future<void> setPresentationMode(bool on) async {
    if (on == presentationMode) return;
    presentationMode = on;
    armedMark = MarkTarget.none;
    if (on) {
      if (tuning.exposure == ExposureControl.manual || tuning.aeLocked) {
        await applyTuning(tuning.resetExposure());
        _setMessage('Presentation Mode adjusts exposure automatically, so manual exposure was turned off.');
      }
      // A locked tap point would fight the profile's exposure choice.
      if (focusMarker?.meter == true) await cancelFocusLock();
    } else {
      presenterMark = null;
      slideMark = null;
      lastAdvice = null;
      if (tuning.evIndex != 0) await applyTuning(tuning.copyWith(evIndex: 0), quiet: true);
    }
    sceneWarnings = const [];
    _runsSinceAutoEv = _settleRuns;
    _updateAnalysisTimer();
    _notify();
  }

  Future<void> setPresentationProfile(PresentationProfile p) async {
    presentationProfile = p;
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_profileKey, p.name);
    } catch (_) {}
  }

  Future<void> cyclePresentationProfile() => setPresentationProfile(
      PresentationProfile.values[(presentationProfile.index + 1) % PresentationProfile.values.length]);

  Future<void> setExposureWarnings(bool on) async {
    exposureWarnings = on;
    if (!on && !presentationMode) sceneWarnings = const [];
    _updateAnalysisTimer();
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_warningsKey, on);
    } catch (_) {}
  }

  void armMark(MarkTarget target) {
    armedMark = armedMark == target ? MarkTarget.none : target;
    _notify();
  }

  void clearMarks() {
    presenterMark = null;
    slideMark = null;
    armedMark = MarkTarget.none;
    _notify();
  }

  FrameGeometry _geometry(CameraController c) {
    final desc = c.description;
    final deviceDeg = switch (c.value.deviceOrientation) {
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
      _ => 0,
    };
    final front = desc.lensDirection == CameraLensDirection.front;
    return FrameGeometry(
      rotation: FrameGeometry.rotationFor(sensorOrientation: desc.sensorOrientation, deviceRotation: deviceDeg, front: front),
      mirrored: front,
    );
  }

  void _placeMark(MarkTarget target, double x, double y) {
    final c = camera;
    if (c == null) return;
    final geo = lastGeometry ?? _geometry(c);
    final p = geo.displayToUpright(x, y);
    final b = geo.uprightToBuffer(p.x, p.y);
    if (target == MarkTarget.presenter) {
      // About the size of a face at classroom distance.
      final display = NormRect.centered(x, y, 0.07, 0.05);
      presenterMark = SceneMark(geo.displayRectToBuffer(display), display);
    } else {
      final grid = _lastGrid;
      final buffer = grid != null ? grid.slideAround(b.x, b.y) : geo.displayRectToBuffer(NormRect.centered(x, y, 0.15, 0.1));
      slideMark = SceneMark(buffer, geo.bufferRectToDisplay(buffer));
    }
    armedMark = MarkTarget.none;
    _notify();
  }

  // ------------------------------------------------------------------ preview analysis

  bool get _analysisWanted =>
      _appActive &&
      !_covered &&
      initialized &&
      _session != null &&
      !videoModeActive &&
      !isVideoRecording &&
      (presentationMode || exposureWarnings) &&
      tuningBridge.available;

  /// True while the periodic analysis loop is scheduled (there is never more than one).
  @visibleForTesting
  bool get analysisLoopActive => _analysisTimer != null;

  void _updateAnalysisTimer() {
    if (_analysisWanted) {
      _analysisTimer ??= Timer.periodic(_analysisInterval, (_) => _analysisTick());
    } else {
      _stopAnalysisTimer();
      _cancelAnalysisRun();
      if (sceneWarnings.isNotEmpty) {
        sceneWarnings = const [];
        _notify();
      }
    }
  }

  void _stopAnalysisTimer() {
    _analysisTimer?.cancel();
    _analysisTimer = null;
  }

  /// Gives up the analysis slot. The run's result will be discarded; its frame wait ends now.
  void _cancelAnalysisRun() {
    final run = _analysisRun;
    _analysisRun = null;
    run?.cancelled = true;
    _frameGrab?.abort();
  }

  bool _runIsCurrent(_AnalysisRun run) =>
      !run.cancelled &&
      identical(_analysisRun, run) &&
      _isLive(run.session) &&
      run.captureEpoch == _captureEpoch &&
      _protectedOps == 0;

  void _analysisTick() {
    final running = _analysisRun;
    if (running != null) {
      if (++running.ticksWaited < _analysisRunTicks) return;
      _cancelAnalysisRun(); // stuck (e.g. a very slow face detection): abandon it
    }
    final s = _session;
    if (s == null || _protectedOps > 0 || busy || !_analysisWanted) return;
    final run = _AnalysisRun(s, _captureEpoch);
    _analysisRun = run;
    _analyze(run).catchError((Object _) {}).whenComplete(() {
      if (identical(_analysisRun, run)) _analysisRun = null;
    });
  }

  /// Closes a preview-frame stream opened on [c] and releases a waiting frame read.
  Future<void> _closeFrameStream(CameraController c) async {
    final grab = _frameGrab;
    if (grab != null && identical(grab.controller, c)) grab.abort();
    if (c.value.isStreamingImages) {
      try {
        await c.stopImageStream();
      } catch (_) {}
    }
  }

  /// Reads one preview frame: opens the frame stream, takes the first frame, closes the stream.
  Future<CameraImage?> _grabFrame(_AnalysisRun run) async {
    final c = run.session.controller;
    if (!_runIsCurrent(run) ||
        !c.value.isInitialized ||
        c.value.isStreamingImages ||
        c.value.isTakingPicture ||
        c.value.isRecordingVideo) {
      return null;
    }
    final grab = _FrameGrab(c);
    _frameGrab = grab;
    try {
      await c.startImageStream(grab.deliver);
      // Normally the first frame arrives within a frame interval. If the camera stops delivering,
      // the read gives up instead of holding the stream open.
      return await grab.result.timeout(const Duration(seconds: 1), onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      if (identical(_frameGrab, grab)) _frameGrab = null;
      if (c.value.isStreamingImages) {
        try {
          await c.stopImageStream();
        } catch (_) {}
      }
    }
  }

  Future<void> _analyze(_AnalysisRun run) async {
    final c = run.session.controller;
    final image = await _grabFrame(run);
    if (image == null || !_runIsCurrent(run)) return;
    final geo = _geometry(c);
    final frame = await _sceneAnalyzer.analyze(image, geo, detectFaces: presentationMode);
    // Discard the result if the camera changed, the page paused, or a capture started meanwhile.
    if (frame == null || !_runIsCurrent(run)) return;
    lastGeometry = geo;
    _lastGrid = frame.grid;
    final m = buildMeasurement(frame, presenterMark: presenterMark?.buffer, slideMark: slideMark?.buffer);
    lastMeasurement = m;
    var warnings = frameWarnings(m.global);
    if (presentationMode) {
      final advice = advisePresentation(
        profile: presentationProfile,
        m: m,
        currentIndex: tuning.evIndex,
        minIndex: capabilities.aeCompensationMin,
        maxIndex: capabilities.aeCompensationMax,
        step: capabilities.exposureCompensation ? capabilities.aeCompensationStep : 0,
      );
      lastAdvice = advice;
      warnings = advice.warnings;
      final settled = _runsSinceAutoEv >= _settleRuns;
      _runsSinceAutoEv++;
      final canAdjust = capabilities.exposureCompensation && tuning.exposure == ExposureControl.auto && !tuning.aeLocked;
      if (canAdjust && settled && advice.targetIndex != tuning.evIndex) {
        // Tagged with the run's capture epoch: dropped by the worker if a capture starts first.
        unawaited(_submitTuning(_TuningRequest(
          tuning.copyWith(evIndex: advice.targetIndex),
          run.session,
          automaticEpoch: run.captureEpoch,
          quiet: true,
        )));
      }
    } else {
      lastAdvice = null;
    }
    sceneWarnings = (presentationMode || exposureWarnings) ? warnings : const [];
    _notify();
  }

  // ------------------------------------------------------------------ app lifecycle

  void onAppPaused() {
    _appActive = false;
    _updateAnalysisTimer();
    final c = camera;
    if (c != null) unawaited(_closeFrameStream(c));
  }

  /// CameraX closes the camera in the background and may reset exposure compensation when it
  /// reopens, so the user's settings are re-sent once the app is back.
  Future<void> onAppResumed() async {
    _appActive = true;
    await _resendTuning(tuning);
    _updateAnalysisTimer();
  }

  /// Another page is on top of the camera page: no preview analysis meanwhile. When that page uses
  /// the camera itself ([releasesCamera], e.g. the QR scanner), manual settings are removed from
  /// the camera first and re-applied on return, so they never affect the other page.
  Future<void> setCovered(bool covered, {bool releasesCamera = false}) async {
    if (covered == _covered) return;
    _covered = covered;
    final s = _session;
    if (covered) {
      _updateAnalysisTimer();
      if (s == null) return;
      await _closeFrameStream(s.controller);
      if (releasesCamera && s.touched) {
        _resumeTuningAfterCover = tuning;
        focusMarker = null;
        await _submitTuning(_TuningRequest(CameraTuning.automatic, s, resend: true, quiet: true));
      }
    } else {
      final want = _resumeTuningAfterCover ?? tuning;
      _resumeTuningAfterCover = null;
      await _resendTuning(want);
      _updateAnalysisTimer();
    }
  }

  Future<void> _resendTuning(CameraTuning want) async {
    focusMarker = null; // a locked tap point does not survive the camera closing
    final s = _session;
    if (s != null && s.touched && tuningBridge.available && capabilities != CameraCapabilities.none) {
      await _submitTuning(_TuningRequest(want, s, resend: true, quiet: true));
    }
    _notify();
  }

  // ------------------------------------------------------------------ control check (proof of concept)

  /// Checks, on this phone, that the native bridge acts on the same live camera the plugin shows:
  /// the plugin sets exposure compensation and the bridge must read the same value back; then the
  /// bridge sets it and reads it again; then a tap-to-focus at the centre is requested.
  /// Watch the preview: its brightness should visibly change during the exposure steps.
  Future<List<ControlCheckStep>> runControlCheck() async {
    final s = _session;
    final steps = <ControlCheckStep>[];
    if (s == null || !s.controller.value.isInitialized) {
      return const [ControlCheckStep('Camera ready', false, 'The camera is not initialised.')];
    }
    if (!tuningBridge.available) {
      return const [ControlCheckStep('Native bridge', null, 'Only available on Android.')];
    }
    final c = s.controller;
    // Let queued settings finish first: once protected, user changes would wait for the check and
    // the check would wait for them.
    await _tuningDone;
    if (!_isLive(s)) return const [ControlCheckStep('Check stopped', false, 'The camera changed before the check.')];
    // Protected: analysis pauses and no automatic change runs while the check drives the camera.
    _beginProtected();
    try {
      final probe = await _bridge(s, (id) => tuningBridge.probe(id));
      steps.add(ControlCheckStep(
        'Bridge reaches the open camera',
        probe.cameraId == s.cameraId && probe.state == 'OPEN',
        'camera ${probe.cameraId} (expected ${s.cameraId}), state ${probe.state}',
      ));
      if (!probe.exposureSupported || probe.exposureStep <= 0) {
        steps.add(const ControlCheckStep('Shared exposure control', null, 'This camera has no exposure compensation.'));
      } else {
        final stepEv = probe.exposureStep;
        final stride = max(1, (1 / stepEv).round()); // about +1 EV: clearly visible
        s.touched = true;
        final applied = await c.setExposureOffset(stride * stepEv); // the plugin's own API
        if (!_isLive(s)) throw const _StaleOperation();
        await Future<void>.delayed(const Duration(milliseconds: 800)); // let the user see the change
        final seen = await _bridge(s, (id) => tuningBridge.probe(id));
        final expected = (applied / stepEv).round();
        steps.add(ControlCheckStep(
          'Plugin change is visible to the bridge',
          seen.exposureIndex == expected,
          'plugin set ${applied.toStringAsFixed(2)} EV (index $expected); bridge reads index ${seen.exposureIndex}',
        ));
        final set = await _bridge(s, (id) => tuningBridge.setExposureIndex(id, -stride));
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final seen2 = await _bridge(s, (id) => tuningBridge.probe(id));
        steps.add(ControlCheckStep(
          'Bridge sets exposure on the live camera',
          set == -stride && seen2.exposureIndex == -stride,
          'bridge set index ${-stride} (applied $set); read back ${seen2.exposureIndex}',
        ));
      }
      if (capabilities.tapToFocus) {
        final r = await _bridge(s, (id) => tuningBridge.focusAndMeter(id, x: 0.5, y: 0.5, af: true, ae: false));
        steps.add(ControlCheckStep(
          'Tap-to-focus request at the centre',
          r.focusRequested && !r.cancelled,
          r.focusSuccessful
              ? 'camera reported focus achieved'
              : 'request completed; camera did not confirm focus (point at something with detail and retry)',
        ));
      } else {
        steps.add(const ControlCheckStep('Tap-to-focus', null, 'This camera does not report autofocus regions.'));
      }
      final after = await _bridge(s, (id) => tuningBridge.probe(id));
      steps.add(ControlCheckStep('Camera still open afterwards', after.state == 'OPEN' && c.value.isInitialized,
          'state ${after.state}'));
    } on _StaleOperation {
      steps.add(const ControlCheckStep('Check stopped', false, 'The camera changed or closed during the check.'));
    } catch (e) {
      steps.add(ControlCheckStep('Check stopped', false, _errorText(e)));
    } finally {
      // Put back the exposure the user had.
      try {
        await _bridge(s, (id) => tuningBridge.setExposureIndex(id, s.applied.evIndex));
      } catch (_) {}
      _endProtected();
    }
    return steps;
  }

  String _errorText(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    if (e is CameraException) return e.description ?? e.code;
    return e.toString();
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
    if (_disposed) return; // async work finishing after the page closed has nobody to tell
    message = value;
    notifyListeners();
  }

  Future<void> _saveVideoToGallery(String path) async {
    if (kIsWeb) return;
    try {
      await Gal.putVideo(path, album: 'GeoCam');
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    final session = _closeSession();
    _stopAnalysisTimer();
    _focusMarkerTimer?.cancel();
    _positionSubscription?.cancel();
    _gpsClockSubscription?.cancel();
    // Wake anything waiting for a capture to finish; it will see the closed session and stop.
    final idle = _captureIdleCompleter;
    _captureIdleCompleter = null;
    idle?.complete();
    unawaited(_sceneAnalyzer.dispose());
    final c = camera;
    camera = null;
    if (c != null) unawaited(_releaseCamera(c, session));
    super.dispose();
  }
}
