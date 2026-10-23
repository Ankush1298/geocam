import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/models/camera_tuning.dart';
import 'package:geocam/services/camera_tuning_bridge.dart';

const fullCaps = CameraCapabilities(
  hardwareLevel: 'full',
  manualSensor: true,
  isoRange: [100, 3200],
  exposureTimeRangeNs: [100000, 500000000],
  aeCompensationMin: -12,
  aeCompensationMax: 12,
  aeCompensationStep: 1 / 6,
  aeLockAvailable: true,
  awbLockAvailable: true,
  aeModes: [0, 1, 2, 3],
  afModes: [0, 1, 2, 3, 4],
  awbModes: [0, 1, 2, 3, 5, 6],
  minFocusDistance: 10,
  maxRegionsAe: 1,
  maxRegionsAf: 1,
);

const basicCaps = CameraCapabilities(
  hardwareLevel: 'limited',
  aeCompensationMin: -4,
  aeCompensationMax: 4,
  aeCompensationStep: 0.5,
  aeModes: [1],
  afModes: [1, 4],
  awbModes: [1],
  maxRegionsAe: 1,
  maxRegionsAf: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraTuning', () {
    test('automatic sends no overrides', () {
      expect(CameraTuning.automatic.isAllAuto, isTrue);
      expect(CameraTuning.automatic.nativeOverrides(), isEmpty);
    });

    test('manual exposure sends ISO and shutter, never AE lock with them', () {
      final t = CameraTuning.automatic.copyWith(exposure: ExposureControl.manual, iso: 400, exposureNs: 8333333, aeLocked: true);
      expect(t.nativeOverrides(), {'iso': 400, 'exposureNs': 8333333});
      expect(t.exposureIsAuto, isFalse);
    });

    test('AE lock, manual focus, white balance preset and lock map to their keys', () {
      final t = CameraTuning.automatic.copyWith(aeLocked: true, focus: FocusControl.manual, focusDiopters: 2.5, awbMode: 5, awbLocked: true);
      expect(t.nativeOverrides(), {'aeLock': true, 'focusDiopters': 2.5, 'awbMode': 5, 'awbLock': true});
    });

    test('exposure compensation alone is not a Camera2 override', () {
      final t = CameraTuning.automatic.copyWith(evIndex: 3);
      expect(t.nativeOverrides(), isEmpty);
      expect(t.exposureIsAuto, isFalse, reason: 'shown as adjusted');
    });

    test('resets return each section to automatic', () {
      final t = CameraTuning.automatic.copyWith(
          evIndex: 2, aeLocked: true, exposure: ExposureControl.manual, focus: FocusControl.manual, awbMode: 6, awbLocked: true);
      expect(t.resetExposure().exposureIsAuto, isTrue);
      expect(t.resetFocus().focusIsAuto, isTrue);
      expect(t.resetWhiteBalance().whiteBalanceIsAuto, isTrue);
      expect(t.resetExposure().resetFocus().resetWhiteBalance().isAllAuto, isTrue);
    });

    test('unsupported controls are dropped for a basic camera', () {
      final t = CameraTuning.automatic
          .copyWith(
            evIndex: 9,
            aeLocked: true,
            exposure: ExposureControl.manual,
            focus: FocusControl.manual,
            awbMode: 5,
            awbLocked: true,
          )
          .supportedBy(basicCaps);
      expect(t.exposure, ExposureControl.auto);
      expect(t.focus, FocusControl.auto);
      expect(t.awbMode, Camera2.awbModeAuto);
      expect(t.aeLocked, isFalse);
      expect(t.awbLocked, isFalse);
      expect(t.evIndex, 4, reason: 'clamped to the reported range');
    });

    test('values are clamped to the reported ranges', () {
      final t = CameraTuning.automatic
          .copyWith(exposure: ExposureControl.manual, iso: 25600, exposureNs: 2000000000, focus: FocusControl.manual, focusDiopters: 50)
          .supportedBy(fullCaps);
      expect(t.iso, 3200);
      expect(t.exposureNs, 500000000);
      expect(t.focusDiopters, 10);
    });

    test('a preset the camera does not list falls back to automatic', () {
      final t = CameraTuning.automatic.copyWith(awbMode: 8).supportedBy(fullCaps);
      expect(t.awbMode, Camera2.awbModeAuto);
    });

    test('no capabilities means fully automatic', () {
      final t = CameraTuning.automatic
          .copyWith(evIndex: 2, exposure: ExposureControl.manual, focus: FocusControl.manual, awbMode: 5)
          .supportedBy(CameraCapabilities.none);
      expect(t.isAllAuto, isTrue);
    });
  });

  group('ManualStops', () {
    test('ISO stops are limited to the reported range', () {
      expect(ManualStops.iso([100, 800]), [100, 125, 160, 200, 250, 320, 400, 500, 640, 800]);
    });

    test('shutter stops stop at 1/4 s and respect the range', () {
      final s = ManualStops.shutterNs([100000, 500000000]);
      expect(s.first, 125000); // 1/8000 s
      expect(s.last, 250000000);
      expect(s.every((ns) => ns >= 100000 && ns <= 500000000), isTrue);
    });

    test('labels and nearest stop', () {
      expect(ManualStops.shutterLabel(16666666), '1/60 s');
      expect(ManualStops.shutterLabel(250000000), '1/4 s');
      expect(ManualStops.nearest([100, 200, 400], 290), 1);
    });
  });

  group('CameraCapabilities', () {
    test('parses the native map', () {
      final c = CameraCapabilities.fromMap(const {
        'hardwareLevel': 'full',
        'manualSensor': true,
        'isoRange': [50, 6400],
        'exposureTimeRangeNs': [20000, 1000000000],
        'aeCompensationRange': [-12, 12],
        'aeCompensationStep': 0.16666666,
        'aeLockAvailable': true,
        'awbLockAvailable': false,
        'aeModes': [0, 1],
        'afModes': [0, 1, 4],
        'awbModes': [1, 2, 5, 6, 0],
        'minFocusDistance': 8.5,
        'maxRegionsAe': 1,
        'maxRegionsAf': 1,
        'maxRegionsAwb': 0,
      });
      expect(c.manualExposure, isTrue);
      expect(c.manualFocus, isTrue);
      expect(c.tapToFocus, isTrue);
      expect(c.tapToMeter, isTrue);
      expect(c.exposureCompensation, isTrue);
      expect(c.whiteBalancePresets, [5, 6, 2], reason: 'display order, no Auto/Off');
      expect(c.evFor(3), closeTo(0.5, 1e-6));
    });

    test('missing or malformed fields mean unsupported', () {
      final c = CameraCapabilities.fromMap(const {'isoRange': [100], 'aeCompensationRange': 'x', 'afModes': null});
      expect(c.manualExposure, isFalse);
      expect(c.exposureCompensation, isFalse);
      expect(c.tapToFocus, isFalse);
      expect(c.manualFocus, isFalse);
      expect(c.whiteBalancePresets, isEmpty);
    });

    test('fixed-focus lens offers no focus controls', () {
      const c = CameraCapabilities(afModes: [0], minFocusDistance: 0, maxRegionsAf: 0);
      expect(c.autofocus, isFalse);
      expect(c.manualFocus, isFalse);
      expect(c.tapToFocus, isFalse);
    });

    test('manual sensor without AE off mode is not manual exposure', () {
      const c = CameraCapabilities(manualSensor: true, isoRange: [100, 800], exposureTimeRangeNs: [1000, 1000000], aeModes: [1]);
      expect(c.manualExposure, isFalse);
    });
  });

  group('CameraTuningBridge channel contract', () {
    final calls = <MethodCall>[];
    const channel = MethodChannel(CameraTuningBridge.channelName);

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'setExposureIndex':
            return 4; // the camera applied a different value than requested
          case 'focusAndMeter':
            return {'focusSuccessful': true, 'af': true, 'ae': false};
          case 'probe':
            return {'cameraId': '0', 'cameraState': 'OPEN', 'exposureSupported': true, 'exposureIndex': 2, 'exposureStep': 0.5};
          case 'capabilities':
            return {'aeCompensationRange': [-4, 4], 'aeCompensationStep': 0.5};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('every call names the camera and the applied value is returned', () async {
      final b = CameraTuningBridge();
      expect(await b.setExposureIndex('1', 5), 4);
      final r = await b.focusAndMeter('1', x: .25, y: .75, ae: false);
      expect(r.focusSuccessful, isTrue);
      expect(r.meterRequested, isFalse);
      await b.applyOverrides('1', const {'awbMode': 5});
      final caps = await b.capabilities('1');
      expect(caps.exposureCompensation, isTrue);
      final p = await b.probe('1');
      expect(p.exposureIndex, 2);
      expect(calls.map((c) => (c.arguments as Map)['cameraId']).toSet(), {'1'});
      final focus = calls.firstWhere((c) => c.method == 'focusAndMeter').arguments as Map;
      expect(focus['x'], .25);
      expect(focus['y'], .75);
      expect(focus['af'], isTrue);
      expect(focus['ae'], isFalse);
      expect(focus['lock'], isFalse);
      expect((calls.firstWhere((c) => c.method == 'applyOverrides').arguments as Map)['awbMode'], 5);
    });

    test('an empty override set asks for automatic mode', () async {
      await CameraTuningBridge().applyOverrides('0', const {});
      expect(calls.single.arguments, {'cameraId': '0'});
    });
  });
}
