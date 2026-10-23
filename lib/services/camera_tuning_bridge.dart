import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Camera2 metadata constants used by the tuning UI (values from android.hardware.camera2.CameraMetadata).
class Camera2 {
  static const afModeOff = 0;
  static const afModeAuto = 1;
  static const aeModeOff = 0;
  static const awbModeAuto = 1;
  static const awbPresetLabels = <int, String>{
    5: 'Daylight',
    6: 'Cloudy',
    8: 'Shade',
    7: 'Twilight',
    2: 'Incandescent',
    3: 'Fluorescent',
    4: 'Warm fluorescent',
  };
}

/// What the active camera reports it supports. Reported support is not proof that a control
/// works on a given phone; the UI only offers controls listed here.
@immutable
class CameraCapabilities {
  final String hardwareLevel;
  final bool manualSensor;
  final List<int>? isoRange;
  final List<int>? exposureTimeRangeNs;
  final int aeCompensationMin;
  final int aeCompensationMax;
  final double aeCompensationStep;
  final bool aeLockAvailable;
  final bool awbLockAvailable;
  final List<int> aeModes;
  final List<int> afModes;
  final List<int> awbModes;
  final double minFocusDistance;
  final int maxRegionsAe;
  final int maxRegionsAf;
  final int maxRegionsAwb;

  const CameraCapabilities({
    this.hardwareLevel = 'unknown',
    this.manualSensor = false,
    this.isoRange,
    this.exposureTimeRangeNs,
    this.aeCompensationMin = 0,
    this.aeCompensationMax = 0,
    this.aeCompensationStep = 0,
    this.aeLockAvailable = false,
    this.awbLockAvailable = false,
    this.aeModes = const [],
    this.afModes = const [],
    this.awbModes = const [],
    this.minFocusDistance = 0,
    this.maxRegionsAe = 0,
    this.maxRegionsAf = 0,
    this.maxRegionsAwb = 0,
  });

  /// No controls at all: used when the bridge is unavailable (web, tests, errors).
  static const none = CameraCapabilities();

  bool get exposureCompensation => aeCompensationStep > 0 && aeCompensationMax > aeCompensationMin;
  bool get manualExposure =>
      manualSensor && isoRange != null && exposureTimeRangeNs != null && aeModes.contains(Camera2.aeModeOff);
  bool get manualFocus => minFocusDistance > 0 && afModes.contains(Camera2.afModeOff);
  bool get tapToFocus => maxRegionsAf > 0 && afModes.contains(Camera2.afModeAuto);
  bool get tapToMeter => maxRegionsAe > 0;
  bool get autofocus => afModes.any((m) => m != Camera2.afModeOff);

  /// Presets the camera lists, in display order. Auto and Off are not presets.
  List<int> get whiteBalancePresets =>
      Camera2.awbPresetLabels.keys.where(awbModes.contains).toList(growable: false);

  double evFor(int index) => index * aeCompensationStep;

  factory CameraCapabilities.fromMap(Map<Object?, Object?> m) {
    List<int>? pair(Object? v) {
      if (v is! List || v.length != 2) return null;
      final a = v[0], b = v[1];
      if (a is! num || b is! num) return null;
      return [a.toInt(), b.toInt()];
    }

    List<int> ints(Object? v) => v is List ? v.whereType<num>().map((e) => e.toInt()).toList() : const [];
    int i(Object? v) => v is num ? v.toInt() : 0;
    final comp = pair(m['aeCompensationRange']);
    return CameraCapabilities(
      hardwareLevel: m['hardwareLevel'] is String ? m['hardwareLevel'] as String : 'unknown',
      manualSensor: m['manualSensor'] == true,
      isoRange: pair(m['isoRange']),
      exposureTimeRangeNs: pair(m['exposureTimeRangeNs']),
      aeCompensationMin: comp?[0] ?? 0,
      aeCompensationMax: comp?[1] ?? 0,
      aeCompensationStep: m['aeCompensationStep'] is num ? (m['aeCompensationStep'] as num).toDouble() : 0,
      aeLockAvailable: m['aeLockAvailable'] == true,
      awbLockAvailable: m['awbLockAvailable'] == true,
      aeModes: ints(m['aeModes']),
      afModes: ints(m['afModes']),
      awbModes: ints(m['awbModes']),
      minFocusDistance: m['minFocusDistance'] is num ? (m['minFocusDistance'] as num).toDouble() : 0,
      maxRegionsAe: i(m['maxRegionsAe']),
      maxRegionsAf: i(m['maxRegionsAf']),
      maxRegionsAwb: i(m['maxRegionsAwb']),
    );
  }
}

/// Result of a tap-to-focus/meter request.
@immutable
class FocusMeterResult {
  final bool focusRequested;
  final bool meterRequested;
  final bool focusSuccessful;
  final bool cancelled;
  const FocusMeterResult({
    required this.focusRequested,
    required this.meterRequested,
    required this.focusSuccessful,
    this.cancelled = false,
  });
}

/// Live state read back from the plugin's camera (used by the ownership check).
@immutable
class CameraProbe {
  final String cameraId;
  final String? state;
  final bool exposureSupported;
  final int exposureIndex;
  final double exposureStep;
  const CameraProbe(this.cameraId, this.state, this.exposureSupported, this.exposureIndex, this.exposureStep);
}

/// Dart side of `CameraTuningBridge.kt`. All calls name the camera (the plugin's camera name is the
/// Camera2 camera id) so a call can never act on a different camera than the one on screen.
class CameraTuningBridge {
  static const channelName = 'geocam/camera_tuning';
  final MethodChannel _channel;
  CameraTuningBridge([MethodChannel? channel]) : _channel = channel ?? const MethodChannel(channelName);

  bool get available => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<CameraCapabilities> capabilities(String cameraId) async {
    if (!available) return CameraCapabilities.none;
    final m = await _channel.invokeMapMethod<Object?, Object?>('capabilities', {'cameraId': cameraId});
    return m == null ? CameraCapabilities.none : CameraCapabilities.fromMap(m);
  }

  Future<CameraProbe> probe(String cameraId) async {
    final m = await _channel.invokeMapMethod<Object?, Object?>('probe', {'cameraId': cameraId}) ?? const {};
    return CameraProbe(
      m['cameraId'] as String? ?? '',
      m['cameraState'] as String?,
      m['exposureSupported'] == true,
      (m['exposureIndex'] as num?)?.toInt() ?? 0,
      (m['exposureStep'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Returns the index the camera actually applied.
  Future<int> setExposureIndex(String cameraId, int index) async {
    final r = await _channel.invokeMethod<int>('setExposureIndex', {'cameraId': cameraId, 'index': index});
    return r ?? index;
  }

  /// [x], [y]: 0..1 over the preview as displayed. [lock] keeps the region until cancelled;
  /// otherwise the camera returns to continuous behaviour after a few seconds.
  Future<FocusMeterResult> focusAndMeter(
    String cameraId, {
    required double x,
    required double y,
    bool af = true,
    bool ae = true,
    bool lock = false,
    double size = 0.15,
  }) async {
    final m = await _channel.invokeMapMethod<Object?, Object?>('focusAndMeter', {
          'cameraId': cameraId,
          'x': x,
          'y': y,
          'af': af,
          'ae': ae,
          'awb': false,
          'lock': lock,
          'size': size,
        }) ??
        const {};
    return FocusMeterResult(
      focusRequested: m['af'] == true,
      meterRequested: m['ae'] == true,
      focusSuccessful: m['focusSuccessful'] == true,
      cancelled: m['cancelled'] == true,
    );
  }

  Future<void> cancelFocusAndMeter(String cameraId) =>
      _channel.invokeMethod<void>('cancelFocusAndMeter', {'cameraId': cameraId});

  /// Replaces all manual overrides; an empty map returns the camera to automatic control.
  Future<void> applyOverrides(String cameraId, Map<String, Object> overrides) =>
      _channel.invokeMethod<void>('applyOverrides', {'cameraId': cameraId, ...overrides});
}
