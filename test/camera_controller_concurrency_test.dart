import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/camera/camera_controller.dart';
import 'package:geocam/models/camera_frame.dart';
import 'package:geocam/models/camera_tuning.dart';
import 'package:geocam/models/stamp_settings.dart';
import 'package:geocam/services/camera_tuning_bridge.dart';
import 'package:geocam/services/photo_processor.dart';
import 'package:geocam/services/video_processor.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/camera_fakes.dart';

/// Stamping that never finishes: these tests are about the camera, not the capture pipeline
/// (capture_integrity_test.dart covers that with the real processor).
class _ParkedPhotoProcessor extends PhotoProcessor {
  @override
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
  }) =>
      Completer<Uint8List>().future;
}

class _ParkedVideoProcessor extends VideoProcessor {
  @override
  Future<String> stampVideo({
    required String inputPath,
    required Position? position,
    required String address,
    required DateTime timestamp,
    required String recordId,
    required StampSettings settings,
    bool isFrontCamera = false,
  }) =>
      Completer<String>().future;
}

const tick = Duration(milliseconds: 500);

void main() {
  late CameraRig rig;
  late GeoCameraController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    rig = CameraRig();
    c = GeoCameraController(
      cameras: const [backCamera, frontCamera],
      tuningBridge: rig.bridge,
      sceneAnalyzer: rig.analyzer,
      photoProcessor: _ParkedPhotoProcessor(),
      videoProcessor: _ParkedVideoProcessor(),
      cameraFactory: rig.create,
      analysisInterval: tick,
    );
  });

  /// Opens the camera and lets the per-session reset finish.
  Future<void> open(WidgetTester tester) async {
    await c.initializeCamera();
    await tester.pump();
    expect(c.capabilities, testCaps, reason: 'session prepared');
  }

  Future<void> finish(WidgetTester tester) async {
    c.dispose();
    await tester.pump(const Duration(seconds: 2)); // let release / timers complete
  }

  int nonResetCalls(String cameraId, {int from = 0}) => rig.bridge.calls
      .skip(from)
      .where((k) => k.cameraId == cameraId)
      .where((k) =>
          (k.method == 'applyOverrides' && (k.args as Map).isNotEmpty) ||
          (k.method == 'setExposureIndex' && k.args != 0) ||
          k.method == 'focusAndMeter')
      .length;

  // =========================================================================================== A
  group('A. capture while analysis is running', () {
    testWidgets('the shutter does not wait for a slow analysis', (tester) async {
      await open(tester);
      await tester.pump(tick); // first analysis: frame read, then slow analysis
      await tester.pump();
      expect(rig.analyzer.pending, hasLength(1));
      expect(rig.analyzer.pending.single.isCompleted, isFalse);

      CaptureResult? result;
      unawaited(c.capture(allowWeakGps: true).then((r) => result = r));
      await tester.pump();
      expect(result, isNotNull, reason: 'capture returned while the analysis is still running');
      expect(rig.current.takePictureCalls, 1);
      expect(rig.analyzer.pending.single.isCompleted, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      await finish(tester);
    });

    testWidgets('no new analysis starts during a capture; it resumes afterwards', (tester) async {
      await open(tester);
      rig.analyzer.pending.clear();
      rig.pictureGate = Completer<void>();
      unawaited(c.capture(allowWeakGps: true));
      await tester.pump();
      final startsBefore = rig.streamStarts;
      await tester.pump(tick * 4);
      expect(rig.streamStarts, startsBefore, reason: 'no frame stream opened during the capture');

      rig.pictureGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(tick);
      expect(rig.streamStarts, greaterThan(startsBefore), reason: 'analysis resumed');
      await finish(tester);
    });

    testWidgets('a late analysis result cannot change exposure after the capture began', (tester) async {
      await open(tester);
      await c.setPresentationMode(true);
      await tester.pump(tick);
      await tester.pump();
      expect(rig.analyzer.pending, hasLength(1));
      final mark = rig.bridge.calls.length;

      rig.pictureGate = Completer<void>();
      unawaited(c.capture(allowWeakGps: true));
      await tester.pump();
      rig.analyzer.pending.single.complete(darkFaceFrame()); // would ask for +1/3 EV
      await tester.pump();

      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'setExposureIndex'), isEmpty);
      expect(c.tuning.evIndex, 0);
      expect(c.lastMeasurement, isNull, reason: 'the stale result was not published');

      rig.pictureGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await finish(tester);
    });

    testWidgets('an automatic change queued before the capture is dropped; a user change waits for it', (tester) async {
      await open(tester);
      await c.setPresentationMode(true);
      final overridesGate = rig.bridge.hold('applyOverrides');
      unawaited(c.applyTuning(c.tuning.copyWith(awbMode: 5))); // user change, in flight
      await tester.pump();
      await tester.pump(tick);
      await tester.pump();
      rig.analyzer.pending.single.complete(darkFaceFrame()); // queues an automatic +EV change
      await tester.pump();
      final mark = rig.bridge.calls.length;

      rig.pictureGate = Completer<void>();
      unawaited(c.capture(allowWeakGps: true));
      await tester.pump();
      overridesGate.complete();
      await tester.pump();
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'setExposureIndex'), isEmpty,
          reason: 'automatic change computed before the capture is dropped');

      unawaited(c.applyTuning(c.tuning.copyWith(awbLocked: true))); // user change during the capture
      await tester.pump(tick);
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'applyOverrides'), isEmpty,
          reason: 'user change waits until the photo is taken');

      rig.pictureGate!.complete();
      await tester.pump();
      await tester.pump();
      final after = rig.bridge.calls.skip(mark).where((k) => k.method == 'applyOverrides').toList();
      expect(after, hasLength(1));
      expect(after.single.args, {'awbMode': 5, 'awbLock': true});
      expect(c.tuning.awbLocked, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      await finish(tester);
    });

    testWidgets('an analysis error does not stop analysis', (tester) async {
      await open(tester);
      rig.analyzer.throwNext = StateError('ML Kit failed');
      await tester.pump(tick);
      await tester.pump();
      final callsAfterError = rig.analyzer.calls;
      await tester.pump(tick);
      await tester.pump();
      expect(rig.analyzer.calls, callsAfterError + 1);
      await finish(tester);
    });

    testWidgets('a stuck analysis is abandoned and its late result ignored', (tester) async {
      await open(tester);
      await c.setPresentationMode(true);
      await tester.pump(tick);
      await tester.pump();
      final stuck = rig.analyzer.pending.single;
      await tester.pump(tick * 9);
      await tester.pump();
      expect(rig.analyzer.calls, greaterThan(1), reason: 'a new run started');
      final mark = rig.bridge.calls.length;
      stuck.complete(darkFaceFrame());
      await tester.pump();
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'setExposureIndex'), isEmpty);
      await finish(tester);
    });
  });

  // =========================================================================================== B
  group('B. camera switching with pending work', () {
    testWidgets('pending exposure change for camera A never reaches camera B', (tester) async {
      await open(tester);
      final gate = rig.bridge.hold('setExposureIndex');
      unawaited(c.applyTuning(c.tuning.copyWith(evIndex: 3)));
      await tester.pump();
      expect(rig.bridge.callsFor('0', 'setExposureIndex').last.args, 3);

      await c.switchCamera();
      await tester.pump();
      final mark = rig.bridge.calls.length;
      gate.complete();
      await tester.pump();

      expect(nonResetCalls('1', from: mark), 0);
      expect(c.tuning, CameraTuning.automatic);
      expect(c.message, isNull);
      // Camera A was touched, so it was reset before being disposed.
      final aCalls = rig.bridge.callsFor('0');
      expect(aCalls.any((k) => k.method == 'applyOverrides' && (k.args as Map).isEmpty), isTrue);
      expect(rig.events.indexOf('dispose 0'), greaterThan(-1));
      await finish(tester);
    });

    testWidgets('a pending tap-to-focus result does not mark camera B', (tester) async {
      await open(tester);
      final gate = rig.bridge.hold('focusAndMeter');
      unawaited(c.onPreviewTap(0.3, 0.4));
      await tester.pump();
      await c.switchCamera();
      await tester.pump();
      gate.complete();
      await tester.pump();
      expect(c.focusMarker, isNull);
      expect(c.message, isNull);
      await finish(tester);
    });

    testWidgets('a delayed analysis result from camera A is not published for camera B', (tester) async {
      await open(tester);
      await c.setPresentationMode(true);
      await tester.pump(tick);
      await tester.pump();
      final late = rig.analyzer.pending.single;
      await c.switchCamera();
      await tester.pump();
      final mark = rig.bridge.calls.length;
      late.complete(darkFaceFrame());
      await tester.pump();
      expect(c.lastMeasurement, isNull);
      expect(c.sceneWarnings, isEmpty);
      expect(nonResetCalls('1', from: mark), 0);
      await finish(tester);
    });

    testWidgets('settings restoration started for camera A does not touch camera B', (tester) async {
      await open(tester);
      await c.applyTuning(c.tuning.copyWith(awbMode: 5));
      await tester.pump();
      c.onAppPaused();
      final gate = rig.bridge.hold('applyOverrides');
      unawaited(c.onAppResumed()); // re-sends AWB to camera A, held in flight
      await tester.pump();
      await c.switchCamera();
      await tester.pump();
      final mark = rig.bridge.calls.length;
      gate.complete();
      await tester.pump();
      expect(nonResetCalls('1', from: mark), 0);
      expect(c.tuning, CameraTuning.automatic);
      await finish(tester);
    });

    testWidgets('rapid repeated switching: only the newest session is affected', (tester) async {
      await open(tester);
      final gates = <Completer<void>>[];
      for (var i = 0; i < 3; i++) {
        gates.add(rig.bridge.hold('applyOverrides'));
        unawaited(c.applyTuning(c.tuning.copyWith(awbMode: 5)));
        await tester.pump();
        unawaited(c.switchCamera());
        unawaited(c.switchCamera()); // ignored: the camera is still opening
        await tester.pump();
      }
      // Cameras opened: 0, 1, 0, 1. The last session is camera '1'.
      expect(rig.cameras.map((x) => x.description.name), ['0', '1', '0', '1']);
      expect(rig.cameras.take(3).every((x) => x.disposed), isTrue);
      final mark = rig.bridge.calls.length;
      for (final g in gates) {
        g.complete();
      }
      await tester.pump();
      await tester.pump();
      expect(nonResetCalls('1', from: mark), 0);
      expect(nonResetCalls('0', from: mark), 0);
      expect(c.tuning, CameraTuning.automatic);
      expect(c.capabilities, testCaps);
      await finish(tester);
    });

    testWidgets('a two-step change cut off by switching away and back never lands on the reopened camera',
        (tester) async {
      await open(tester);
      final gate = rig.bridge.hold('applyOverrides');
      // Overrides first (held in flight), then an exposure step that has not been sent yet.
      unawaited(c.applyTuning(c.tuning.copyWith(awbMode: 5, evIndex: 4)));
      await tester.pump();
      await c.switchCamera(); // to '1'
      await tester.pump();
      await c.switchCamera(); // back to '0': a new session for the same physical camera
      await tester.pump();
      expect(rig.cameras.map((x) => x.description.name), ['0', '1', '0']);
      final mark = rig.bridge.calls.length;
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(nonResetCalls('0', from: mark), 0, reason: 'the old request must not reach the reopened camera');
      expect(c.tuning, CameraTuning.automatic);
      await finish(tester);
    });

    testWidgets('a retry for a camera that was still opening is not sent after a switch', (tester) async {
      await open(tester);
      rig.bridge.failNext('setExposureIndex', PlatformException(code: 'camera_not_open'));
      unawaited(c.applyTuning(c.tuning.copyWith(evIndex: 3)));
      await tester.pump(); // first attempt fails; the bridge waits before retrying
      await c.switchCamera();
      await tester.pump();
      final mark = rig.bridge.calls.length;
      await tester.pump(const Duration(seconds: 2)); // past every retry delay
      expect(nonResetCalls('0', from: mark), 0, reason: 'no retry reached the released camera');
      expect(nonResetCalls('1', from: mark), 0);
      await finish(tester);
    });

    testWidgets('an error from a stale operation does not reach the new camera UI', (tester) async {
      await open(tester);
      final gate = rig.bridge.hold('applyOverrides');
      rig.bridge.failNext('applyOverrides', PlatformException(code: 'camera_operation_failed', message: 'boom'));
      unawaited(c.applyTuning(c.tuning.copyWith(focus: FocusControl.manual, focusDiopters: 2)));
      await tester.pump();
      await c.switchCamera();
      await tester.pump();
      gate.complete();
      await tester.pump();
      expect(c.message, isNull);
      expect(c.tuning, CameraTuning.automatic);
      await finish(tester);
    });

    testWidgets('disposing the page with work pending is safe and releases the camera', (tester) async {
      await open(tester);
      final gate = rig.bridge.hold('applyOverrides');
      unawaited(c.applyTuning(c.tuning.copyWith(awbMode: 6)));
      await tester.pump();
      c.dispose();
      gate.complete(); // completes after disposal: must not notify a disposed controller
      await tester.pump(const Duration(seconds: 2));
      expect(rig.current.disposed, isTrue);
      expect(rig.bridge.callsFor('0', 'applyOverrides').last.args, isEmpty, reason: 'overrides cleared on release');
    });
  });

  // =========================================================================================== C
  group('C. recording transitions', () {
    testWidgets('recording starts safely while a frame read is open, and analysis stays off', (tester) async {
      await open(tester);
      rig.deliverFrames = false; // the frame read stays open, holding the stream
      await tester.pump(tick);
      await tester.pump();
      expect(rig.current.value.isStreamingImages, isTrue);

      final started = await c.startVideoRecording();
      expect(started, isTrue, reason: 'the stream was closed first (the fake fails otherwise)');
      expect(rig.current.value.isStreamingImages, isFalse);
      final starts = rig.streamStarts;
      await tester.pump(tick * 4);
      expect(rig.streamStarts, starts, reason: 'no analysis while recording');
      expect(c.analysisLoopActive, isFalse);

      rig.deliverFrames = true;
      await c.stopVideoRecording();
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.analysisLoopActive, isTrue, reason: 'photo mode: analysis resumes after recording');
      await tester.pump(tick);
      expect(rig.streamStarts, greaterThan(starts));
      await finish(tester);
    });

    testWidgets('video mode stops analysis until photo mode returns', (tester) async {
      await open(tester);
      await c.setVideoMode(true);
      expect(c.analysisLoopActive, isFalse);
      final starts = rig.streamStarts;
      await tester.pump(tick * 3);
      expect(rig.streamStarts, starts);
      await c.setVideoMode(false);
      expect(c.analysisLoopActive, isTrue);
      await finish(tester);
    });
  });

  // =========================================================================================== D
  group('D. settings and lifecycle', () {
    testWidgets('reset returns the camera to automatic', (tester) async {
      await open(tester);
      await c.applyTuning(c.tuning.copyWith(evIndex: 2, awbMode: 5));
      await tester.pump();
      final mark = rig.bridge.calls.length;
      await c.resetAllTuning();
      await tester.pump();
      final after = rig.bridge.calls.skip(mark).toList();
      expect(after.where((k) => k.method == 'applyOverrides').single.args, isEmpty);
      expect(after.where((k) => k.method == 'setExposureIndex').single.args, 0);
      expect(c.tuning.isAllAuto, isTrue);
      await finish(tester);
    });

    testWidgets('unsupported controls are never sent', (tester) async {
      rig.bridge.caps = const CameraCapabilities(aeCompensationMin: -4, aeCompensationMax: 4, aeCompensationStep: .5, afModes: [1], maxRegionsAf: 1);
      await c.initializeCamera();
      await tester.pump();
      await c.applyTuning(c.tuning.copyWith(exposure: ExposureControl.manual, iso: 800, focus: FocusControl.manual, awbMode: 5));
      await tester.pump();
      expect(rig.bridge.calls.where((k) => k.method == 'applyOverrides' && (k.args as Map).isNotEmpty), isEmpty);
      expect(c.tuning.isAllAuto, isTrue);
      await finish(tester);
    });

    testWidgets('a native error restores the confirmed settings and is reported', (tester) async {
      await open(tester);
      await c.applyTuning(c.tuning.copyWith(awbMode: 5));
      await tester.pump();
      rig.bridge.failNext('applyOverrides', PlatformException(code: 'unsupported', message: 'no manual focus'));
      await c.applyTuning(c.tuning.copyWith(focus: FocusControl.manual, focusDiopters: 2));
      await tester.pump();
      expect(c.tuning.focus, FocusControl.auto);
      expect(c.tuning.awbMode, 5, reason: 'the confirmed setting is kept');
      expect(rig.bridge.calls.last.args, {'awbMode': 5}, reason: 'confirmed overrides re-sent');
      expect(c.message, contains('no manual focus'));
      await finish(tester);
    });

    testWidgets('background / foreground: one loop only, settings re-sent', (tester) async {
      await open(tester);
      await c.applyTuning(c.tuning.copyWith(awbMode: 5, evIndex: 2));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        c.onAppPaused();
        expect(c.analysisLoopActive, isFalse);
        final starts = rig.streamStarts;
        await tester.pump(tick * 2);
        expect(rig.streamStarts, starts);
        final mark = rig.bridge.calls.length;
        await c.onAppResumed();
        await tester.pump();
        final resent = rig.bridge.calls.skip(mark).toList();
        expect(resent.where((k) => k.method == 'applyOverrides').single.args, {'awbMode': 5});
        expect(resent.where((k) => k.method == 'setExposureIndex').single.args, 2);
      }
      final starts = rig.streamStarts;
      await tester.pump(tick * 4);
      await tester.pump();
      expect(rig.streamStarts - starts, inInclusiveRange(1, 4), reason: 'one loop, not one per resume');
      await finish(tester);
    });

    testWidgets('a page that uses the camera (scanner) gets it without manual settings', (tester) async {
      await open(tester);
      await c.applyTuning(c.tuning.copyWith(focus: FocusControl.manual, focusDiopters: 3));
      await tester.pump();
      var mark = rig.bridge.calls.length;
      await c.setCovered(true, releasesCamera: true);
      await tester.pump();
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'applyOverrides').single.args, isEmpty);
      mark = rig.bridge.calls.length;
      await c.setCovered(false);
      await tester.pump();
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'applyOverrides').single.args,
          {'focusDiopters': 3.0});
      expect(c.tuning.focus, FocusControl.manual);

      // A page that does not use the camera (photo result) leaves settings alone.
      mark = rig.bridge.calls.length;
      await c.setCovered(true);
      await c.setCovered(false);
      await tester.pump();
      expect(rig.bridge.calls.skip(mark).where((k) => k.method == 'applyOverrides' && (k.args as Map).isEmpty), isEmpty);
      await finish(tester);
    });

    testWidgets('a camera that cannot report controls keeps them hidden', (tester) async {
      rig.bridge.failNext('applyOverrides', PlatformException(code: 'camera_lookup_failed'));
      await c.initializeCamera();
      await tester.pump();
      expect(c.capabilities, CameraCapabilities.none);
      await c.applyTuning(c.tuning.copyWith(evIndex: 3));
      await tester.pump();
      expect(rig.bridge.calls.where((k) => k.method == 'setExposureIndex'), isEmpty);
      await finish(tester);
    });
  });
}
