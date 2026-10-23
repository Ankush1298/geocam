import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:geocam/services/camera_tuning_bridge.dart';
import 'package:geocam/services/exposure_meter.dart';
import 'package:geocam/services/scene_analyzer.dart';

/// Test doubles for the camera controller's concurrency tests. They model the behaviour of the
/// real `camera` plugin that matters here (stream / capture / recording state and its errors);
/// they are not evidence of how a real phone behaves.

const backCamera = CameraDescription(name: '0', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
const frontCamera = CameraDescription(name: '1', lensDirection: CameraLensDirection.front, sensorOrientation: 270);

const testCaps = CameraCapabilities(
  hardwareLevel: 'full',
  manualSensor: true,
  isoRange: [100, 3200],
  exposureTimeRangeNs: [100000, 500000000],
  aeCompensationMin: -12,
  aeCompensationMax: 12,
  aeCompensationStep: 1 / 6,
  aeLockAvailable: true,
  awbLockAvailable: true,
  aeModes: [0, 1],
  afModes: [0, 1, 4],
  awbModes: [1, 2, 3, 5, 6],
  minFocusDistance: 10,
  maxRegionsAe: 1,
  maxRegionsAf: 1,
);

class BridgeCall {
  final String method;
  final String cameraId;
  final Object? args;
  BridgeCall(this.method, this.cameraId, [this.args]);
  @override
  String toString() => '$method($cameraId${args == null ? '' : ', $args'})';
}

/// Records every call. A test can hold the next call of a method "in flight" with [hold]; the call
/// is recorded (it reached the native side) but does not return until the gate is released.
class FakeTuningBridge extends CameraTuningBridge {
  FakeTuningBridge() : super(const MethodChannel('test/unused'));

  final calls = <BridgeCall>[];
  CameraCapabilities caps = testCaps;
  final _gates = <String, Completer<void>>{};
  final _failures = <String, Object>{};

  @override
  bool get available => true;

  /// Holds the next call of [method] until the returned completer completes (or fails).
  Completer<void> hold(String method) => _gates[method] = Completer<void>();

  /// Makes the next call of [method] fail with [error].
  void failNext(String method, Object error) => _failures[method] = error;

  Future<void> _pass(String method) async {
    final gate = _gates.remove(method);
    if (gate != null) await gate.future;
    final failure = _failures.remove(method);
    if (failure != null) throw failure;
  }

  List<BridgeCall> callsFor(String cameraId, [String? method]) =>
      calls.where((c) => c.cameraId == cameraId && (method == null || c.method == method)).toList();

  @override
  Future<CameraCapabilities> capabilities(String cameraId) async {
    calls.add(BridgeCall('capabilities', cameraId));
    return caps;
  }

  @override
  Future<CameraProbe> probe(String cameraId) async {
    calls.add(BridgeCall('probe', cameraId));
    return CameraProbe(cameraId, 'OPEN', true, 0, 1 / 6);
  }

  @override
  Future<int> setExposureIndex(String cameraId, int index) async {
    calls.add(BridgeCall('setExposureIndex', cameraId, index));
    await _pass('setExposureIndex');
    return index;
  }

  @override
  Future<FocusMeterResult> focusAndMeter(String cameraId,
      {required double x, required double y, bool af = true, bool ae = true, bool lock = false, double size = 0.15}) async {
    calls.add(BridgeCall('focusAndMeter', cameraId, {'x': x, 'y': y, 'af': af, 'ae': ae, 'lock': lock}));
    await _pass('focusAndMeter');
    return FocusMeterResult(focusRequested: af, meterRequested: ae, focusSuccessful: true);
  }

  @override
  Future<void> cancelFocusAndMeter(String cameraId) async {
    calls.add(BridgeCall('cancelFocusAndMeter', cameraId));
    await _pass('cancelFocusAndMeter');
  }

  @override
  Future<void> applyOverrides(String cameraId, Map<String, Object> overrides) async {
    calls.add(BridgeCall('applyOverrides', cameraId, Map<String, Object>.of(overrides)));
    await _pass('applyOverrides');
  }
}

/// A camera image with an NV21 plane (contents are irrelevant to the fake analyzer).
CameraImage fakeFrame() =>
    // ignore: deprecated_member_use
    CameraImage.fromPlatformData(<dynamic, dynamic>{
      'format': 17, // ImageFormat.NV21
      'width': 8,
      'height': 6,
      'planes': [
        <dynamic, dynamic>{'bytes': Uint8List(72), 'bytesPerRow': 8, 'bytesPerPixel': 1, 'width': 8, 'height': 6},
      ],
    });

/// Shared state and switches for all fake cameras created in one test.
class CameraRig {
  final bridge = FakeTuningBridge();
  final analyzer = FakeSceneAnalyzer();
  final cameras = <FakeCamera>[];
  final events = <String>[];

  /// Deliver a frame as soon as a stream opens; when false the frame read stays waiting.
  bool deliverFrames = true;

  /// When set, takePicture() waits for it (a capture "in progress").
  Completer<void>? pictureGate;

  /// Bytes and path of the photo takePicture() returns (in memory unless a test sets a real file).
  Uint8List pictureBytes = Uint8List.fromList(List<int>.filled(64, 7));
  String picturePath = '/nonexistent/shot.jpg';

  FakeCamera create(CameraDescription d) {
    final c = FakeCamera(d, this);
    cameras.add(c);
    return c;
  }

  FakeCamera get current => cameras.last;
  int get streamStarts => cameras.fold(0, (n, c) => n + c.streamStarts);
}

class FakeCamera extends CameraController {
  FakeCamera(CameraDescription description, this.rig) : super(description, ResolutionPreset.low);

  final CameraRig rig;
  int streamStarts = 0;
  int takePictureCalls = 0;
  bool disposed = false;
  onLatestImageAvailable? _onFrame;

  @override
  Future<void> initialize() async {
    rig.events.add('init ${description.name}');
    value = value.copyWith(isInitialized: true, previewSize: const Size(1920, 1080));
  }

  @override
  Future<double> getMaxZoomLevel() async => 4;

  @override
  Future<void> setZoomLevel(double zoom) async {}

  @override
  Future<void> setFlashMode(FlashMode mode) async {}

  @override
  Future<double> setExposureOffset(double offset) async => offset;

  @override
  Future<void> startImageStream(onLatestImageAvailable onAvailable) async {
    if (value.isRecordingVideo) throw CameraException('recording', 'startImageStream while recording');
    if (value.isStreamingImages) throw CameraException('streaming', 'startImageStream while streaming');
    streamStarts++;
    _onFrame = onAvailable;
    value = value.copyWith(isStreamingImages: true);
    if (rig.deliverFrames) scheduleMicrotask(() => _onFrame?.call(fakeFrame()));
  }

  @override
  Future<void> stopImageStream() async {
    if (!value.isStreamingImages) throw CameraException('not_streaming', 'stopImageStream without a stream');
    _onFrame = null;
    value = value.copyWith(isStreamingImages: false);
  }

  @override
  Future<XFile> takePicture() async {
    if (value.isTakingPicture) throw CameraException('busy', 'takePicture while taking a picture');
    takePictureCalls++;
    rig.events.add('takePicture ${description.name}');
    value = value.copyWith(isTakingPicture: true);
    final gate = rig.pictureGate;
    if (gate != null) await gate.future;
    value = value.copyWith(isTakingPicture: false);
    return XFile.fromData(rig.pictureBytes, path: rig.picturePath);
  }

  @override
  Future<void> startVideoRecording({onLatestImageAvailable? onAvailable, bool enablePersistentRecording = true}) async {
    // The real plugin breaks its stream bookkeeping if recording starts while frames are streamed.
    if (value.isStreamingImages) throw CameraException('stream_open', 'startVideoRecording while streaming');
    rig.events.add('startVideo ${description.name}');
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<XFile> stopVideoRecording() async {
    value = value.copyWith(isRecordingVideo: false);
    return XFile('/nonexistent/clip.mp4');
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    rig.events.add('dispose ${description.name}');
    await super.dispose();
  }
}

/// Analysis whose result the test releases; [throwNext] makes the next call fail.
class FakeSceneAnalyzer extends SceneAnalyzer {
  final pending = <Completer<SceneFrame?>>[];
  Object? throwNext;
  int calls = 0;

  @override
  Future<SceneFrame?> analyze(CameraImage image, FrameGeometry geometry, {required bool detectFaces}) {
    calls++;
    final error = throwNext;
    if (error != null) {
      throwNext = null;
      return Future<SceneFrame?>.error(error);
    }
    final c = Completer<SceneFrame?>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<void> dispose() async {}
}

/// A frame whose measurement makes every profile ask for more exposure: a dark face (detected)
/// and no bright screen.
SceneFrame darkFaceFrame() {
  const w = 40, h = 30;
  final v = Uint8List(w * h)..fillRange(0, w * h, 90);
  for (var y = 9; y < 15; y++) {
    for (var x = 8; x < 14; x++) {
      v[y * w + x] = 35;
    }
  }
  return SceneFrame(LumaGrid(w, h, v), const FrameGeometry(rotation: 0), const [NormRect(0.2, 0.3, 0.35, 0.5)]);
}
