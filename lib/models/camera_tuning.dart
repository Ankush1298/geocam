import 'package:flutter/foundation.dart';

import '../services/camera_tuning_bridge.dart';

enum ExposureControl { auto, manual }

enum FocusControl { auto, manual }

/// User-chosen camera settings. Starts fully automatic; manual values are never persisted, so the
/// app always opens in automatic mode and a camera switch starts from automatic again.
@immutable
class CameraTuning {
  /// Exposure compensation index (EV = index * step). Only used while exposure is automatic.
  final int evIndex;
  final bool aeLocked;
  final ExposureControl exposure;
  final int iso;
  final int exposureNs;
  final FocusControl focus;

  /// Lens position in diopters (0 = infinity, larger = closer). Only used for manual focus.
  final double focusDiopters;

  /// Camera2 AWB mode: 1 = automatic, otherwise one of the reported presets.
  final int awbMode;
  final bool awbLocked;

  const CameraTuning({
    this.evIndex = 0,
    this.aeLocked = false,
    this.exposure = ExposureControl.auto,
    this.iso = 100,
    this.exposureNs = 16666667,
    this.focus = FocusControl.auto,
    this.focusDiopters = 0,
    this.awbMode = Camera2.awbModeAuto,
    this.awbLocked = false,
  });

  static const automatic = CameraTuning();

  bool get exposureIsAuto => exposure == ExposureControl.auto && evIndex == 0 && !aeLocked;
  bool get focusIsAuto => focus == FocusControl.auto;
  bool get whiteBalanceIsAuto => awbMode == Camera2.awbModeAuto && !awbLocked;
  bool get isAllAuto => exposureIsAuto && focusIsAuto && whiteBalanceIsAuto;

  CameraTuning copyWith({
    int? evIndex,
    bool? aeLocked,
    ExposureControl? exposure,
    int? iso,
    int? exposureNs,
    FocusControl? focus,
    double? focusDiopters,
    int? awbMode,
    bool? awbLocked,
  }) =>
      CameraTuning(
        evIndex: evIndex ?? this.evIndex,
        aeLocked: aeLocked ?? this.aeLocked,
        exposure: exposure ?? this.exposure,
        iso: iso ?? this.iso,
        exposureNs: exposureNs ?? this.exposureNs,
        focus: focus ?? this.focus,
        focusDiopters: focusDiopters ?? this.focusDiopters,
        awbMode: awbMode ?? this.awbMode,
        awbLocked: awbLocked ?? this.awbLocked,
      );

  CameraTuning resetExposure() => copyWith(evIndex: 0, aeLocked: false, exposure: ExposureControl.auto);
  CameraTuning resetFocus() => copyWith(focus: FocusControl.auto);
  CameraTuning resetWhiteBalance() => copyWith(awbMode: Camera2.awbModeAuto, awbLocked: false);

  /// Drops anything [caps] does not report and clamps values into the reported ranges.
  CameraTuning supportedBy(CameraCapabilities caps) {
    var t = this;
    if (!caps.exposureCompensation) {
      t = t.copyWith(evIndex: 0);
    } else {
      t = t.copyWith(evIndex: t.evIndex.clamp(caps.aeCompensationMin, caps.aeCompensationMax).toInt());
    }
    if (!caps.aeLockAvailable) t = t.copyWith(aeLocked: false);
    if (t.exposure == ExposureControl.manual) {
      if (!caps.manualExposure) {
        t = t.copyWith(exposure: ExposureControl.auto);
      } else {
        t = t.copyWith(
          iso: t.iso.clamp(caps.isoRange![0], caps.isoRange![1]).toInt(),
          exposureNs: t.exposureNs.clamp(caps.exposureTimeRangeNs![0], caps.exposureTimeRangeNs![1]).toInt(),
        );
      }
    }
    if (t.focus == FocusControl.manual) {
      t = caps.manualFocus
          ? t.copyWith(focusDiopters: t.focusDiopters.clamp(0.0, caps.minFocusDistance).toDouble())
          : t.copyWith(focus: FocusControl.auto);
    }
    if (t.awbMode != Camera2.awbModeAuto && !caps.whiteBalancePresets.contains(t.awbMode)) {
      t = t.copyWith(awbMode: Camera2.awbModeAuto);
    }
    if (!caps.awbLockAvailable) t = t.copyWith(awbLocked: false);
    return t;
  }

  /// Camera2 overrides for the native bridge. Empty = fully automatic. Exposure compensation is
  /// not included: it is a CameraX control, applied separately.
  Map<String, Object> nativeOverrides() {
    final m = <String, Object>{};
    if (exposure == ExposureControl.manual) {
      m['iso'] = iso;
      m['exposureNs'] = exposureNs;
    } else if (aeLocked) {
      m['aeLock'] = true;
    }
    if (focus == FocusControl.manual) m['focusDiopters'] = focusDiopters;
    if (awbMode != Camera2.awbModeAuto) m['awbMode'] = awbMode;
    if (awbLocked) m['awbLock'] = true;
    return m;
  }

  @override
  bool operator ==(Object other) =>
      other is CameraTuning &&
      other.evIndex == evIndex &&
      other.aeLocked == aeLocked &&
      other.exposure == exposure &&
      other.iso == iso &&
      other.exposureNs == exposureNs &&
      other.focus == focus &&
      other.focusDiopters == focusDiopters &&
      other.awbMode == awbMode &&
      other.awbLocked == awbLocked;

  @override
  int get hashCode =>
      Object.hash(evIndex, aeLocked, exposure, iso, exposureNs, focus, focusDiopters, awbMode, awbLocked);
}

/// Standard ISO and shutter stops for the manual sliders, filtered to what the camera reports.
class ManualStops {
  static const _isoStops = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400];

  /// Denominators of 1/x s; the last entries are whole fractions of a second. The slowest offered
  /// speed is 1/4 s: longer exposures freeze the live preview and blur any handheld photo.
  static const _shutterDenominators = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4];

  static List<int> iso(List<int> range) {
    final s = _isoStops.where((v) => v >= range[0] && v <= range[1]).toList();
    return s.isEmpty ? [range[0], range[1]] : s;
  }

  static List<int> shutterNs(List<int> rangeNs) {
    final s = _shutterDenominators
        .map((d) => 1000000000 ~/ d)
        .where((ns) => ns >= rangeNs[0] && ns <= rangeNs[1])
        .toList();
    return s.isEmpty ? [rangeNs[0]] : s;
  }

  static String shutterLabel(int ns) {
    final d = 1000000000 / ns;
    return d >= 1.5 ? '1/${d.round()} s' : '${(ns / 1e9).toStringAsFixed(1)} s';
  }

  /// Index of the stop nearest to [value].
  static int nearest(List<int> stops, int value) {
    var best = 0;
    for (var i = 1; i < stops.length; i++) {
      if ((stops[i] - value).abs() < (stops[best] - value).abs()) best = i;
    }
    return best;
  }
}
