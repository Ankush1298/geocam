import 'dart:math';

import 'package:flutter/foundation.dart';

import 'exposure_meter.dart';

enum PresentationProfile {
  balanced('Balanced', 'Keeps the presenter visible without letting the slide wash out.'),
  facePriority('Face priority', 'Brightens a dark presenter; allows some slide highlights to clip.'),
  slidePriority('Slide priority', 'Protects slide text and graphics; the presenter may be darker.');

  final String label;
  final String description;
  const PresentationProfile(this.label, this.description);
}

/// Where a region measurement came from. Shown to the user so an estimate is never presented as
/// a detection.
enum RegionSource { detectedFace, markedPresenter, estimatedScreen, markedSlide }

@immutable
class MeasuredRegion {
  final NormRect rect; // buffer space
  final RegionStats stats;
  final RegionSource source;
  const MeasuredRegion(this.rect, this.stats, this.source);
}

/// One evaluation of the live preview.
@immutable
class SceneMeasurement {
  final RegionStats global;
  final MeasuredRegion? presenter;
  final MeasuredRegion? slide;
  const SceneMeasurement({required this.global, this.presenter, this.slide});
}

enum SceneWarningKind {
  faceTooDark,
  slideClipped,
  tryBalanced,
  tapToMark,
  rangeExceeded,
  highlightsClipped,
  underexposed,
}

@immutable
class SceneWarning {
  final SceneWarningKind kind;
  final String message;

  /// The measurement behind the warning, so it can be checked.
  final String evidence;
  const SceneWarning(this.kind, this.message, this.evidence);

  @override
  String toString() => '$message ($evidence)';
}

/// Thresholds (8-bit preview luma). Initial values chosen from typical exposure targets; they
/// need checking against real classroom photos.
class ExposureThresholds {
  /// A face whose mid-tones average below this reads as too dark in a photo.
  static const faceDark = 75.0;

  /// Above this a face starts to look washed out.
  static const faceBright = 190.0;

  /// A face this bright is acceptable while darkening to protect the slide.
  static const faceComfortable = 95.0;

  /// Share of the slide area that may be pure white before text and graphics are at risk.
  static const slideClipWarn = 0.05;

  /// Below this share, the slide is treated as safely exposed.
  static const slideClipSafe = 0.01;

  /// Face priority still darkens when this much of the slide is clipped.
  static const slideClipFaceLimit = 0.25;

  /// Whole-frame warnings.
  static const frameClipWarn = 0.04;
  static const frameDarkMean = 45.0;
  static const frameDarkP95 = 140;
}

@immutable
class ExposureAdvice {
  /// Exposure compensation index the profile wants next (may equal the current one).
  final int targetIndex;
  final List<SceneWarning> warnings;

  /// Estimated stops between presenter and slide at the current exposure, if both are measured.
  final double? stopsApart;

  /// True when the presenter is too dark AND the slide is clipped at the same time: no single
  /// exposure fixes both. Balanced then holds the exposure and explains the limit; Face and Slide
  /// priority keep favouring their side, which is what those profiles are for.
  final bool conflict;

  const ExposureAdvice({required this.targetIndex, this.warnings = const [], this.stopsApart, this.conflict = false});
}

String _pct(double f) => '${(f * 100).round()}%';

/// Whole-frame exposure warnings (used outside Presentation Mode too).
List<SceneWarning> frameWarnings(RegionStats g) {
  final w = <SceneWarning>[];
  if (g.clipped > ExposureThresholds.frameClipWarn) {
    w.add(SceneWarning(SceneWarningKind.highlightsClipped, 'Highlights are clipped.',
        '${_pct(g.clipped)} of the frame is pure white in the preview'));
  }
  if (g.mean < ExposureThresholds.frameDarkMean && g.p95 < ExposureThresholds.frameDarkP95) {
    w.add(SceneWarning(SceneWarningKind.underexposed, 'Scene looks underexposed.',
        'average preview brightness ${g.mean.round()}/255'));
  }
  return w;
}

/// Profile allowance for exposure compensation, in EV, as (min, max).
(double, double) evLimits(PresentationProfile p) => switch (p) {
      PresentationProfile.balanced => (-2.0, 1.5),
      PresentationProfile.facePriority => (-1.0, 2.0),
      PresentationProfile.slidePriority => (-2.5, 1.0),
    };

/// Decides the next exposure compensation for Presentation Mode from preview measurements.
///
/// It only ever moves one small step (about 1/3 EV) per evaluation, stays inside the camera's
/// range and the profile's limits, and holds still when the measurements do not justify a change.
ExposureAdvice advisePresentation({
  required PresentationProfile profile,
  required SceneMeasurement m,
  required int currentIndex,
  required int minIndex,
  required int maxIndex,
  required double step,
}) {
  final warnings = <SceneWarning>[];
  final face = m.presenter?.stats;
  final slide = m.slide?.stats;

  final faceDark = face != null && face.mean < ExposureThresholds.faceDark;
  final faceBright = face != null && face.mean > ExposureThresholds.faceBright;
  final slideClip = slide?.clipped ?? 0;
  final slideClipped = slide != null && slideClip > ExposureThresholds.slideClipWarn;
  final slideSafe = slide != null && slideClip < ExposureThresholds.slideClipSafe && slide.p95 < 240;

  if (faceDark) {
    final how = m.presenter!.source == RegionSource.detectedFace ? 'detected face' : 'marked presenter';
    warnings.add(SceneWarning(SceneWarningKind.faceTooDark, 'Face may be too dark.',
        '$how averages ${face.mean.round()}/255 in the preview'));
  }
  if (slideClipped) {
    final how = m.slide!.source == RegionSource.estimatedScreen ? 'estimated slide area' : 'marked slide';
    warnings.add(SceneWarning(SceneWarningKind.slideClipped, 'Slide highlights may be clipped.',
        '${_pct(slideClip)} of the $how is pure white'));
  }
  if (face == null && slide == null) {
    warnings.add(const SceneWarning(SceneWarningKind.tapToMark, 'Tap the presenter or slide to prioritize exposure.',
        'no face detected and no projection screen found'));
  }

  double? stopsApart;
  if (face != null && slide != null) stopsApart = stopsBetween(face.mean, slide.mean);

  final conflict = faceDark && slideClipped;
  if (conflict) {
    warnings.add(SceneWarning(
      SceneWarningKind.rangeExceeded,
      'The presenter and slide are too far apart in brightness for one exposure. '
          'Try a different angle, dimmer room lights near the screen, or more light on the presenter.',
      'face ${face.mean.round()}/255 while ${_pct(slideClip)} of the slide is clipped'
          '${stopsApart != null ? ', at least ${stopsApart.toStringAsFixed(1)} stops apart' : ''}',
    ));
  }
  if (profile == PresentationProfile.facePriority && slideClip > ExposureThresholds.slideClipFaceLimit) {
    warnings.add(SceneWarning(SceneWarningKind.tryBalanced, 'Try Balanced Presentation mode.',
        'Face priority is clipping ${_pct(slideClip)} of the slide'));
  } else if (profile == PresentationProfile.slidePriority && faceDark && !slideClipped) {
    warnings.add(const SceneWarning(SceneWarningKind.tryBalanced, 'Try Balanced Presentation mode.',
        'the slide is safe but the presenter is dark'));
  }

  // One step is about 1/3 EV, never less than one camera step.
  final stride = step > 0 ? max(1, (1 / 3 / step).round()) : 0;
  final (evMin, evMax) = evLimits(profile);
  final lo = step > 0 ? max(minIndex, (evMin / step).ceil()) : currentIndex;
  final hi = step > 0 ? min(maxIndex, (evMax / step).floor()) : currentIndex;

  var delta = 0;
  final hold = conflict && profile == PresentationProfile.balanced;
  if (!hold && stride > 0) {
    switch (profile) {
      case PresentationProfile.balanced:
        if (faceDark && !slideClipped) {
          delta = stride;
        } else if (slideClipped && (face == null || face.mean > ExposureThresholds.faceComfortable)) {
          delta = -stride;
        } else if (faceBright) {
          delta = -stride;
        }
      case PresentationProfile.facePriority:
        if (faceDark && slideClip < ExposureThresholds.slideClipFaceLimit) {
          delta = stride;
        } else if (faceBright || slideClip > ExposureThresholds.slideClipFaceLimit) {
          delta = -stride;
        }
      case PresentationProfile.slidePriority:
        if (slideClipped) {
          delta = -stride;
        } else if (slideSafe && face != null && face.mean < 60 && slide.p95 < 225) {
          delta = stride; // the slide has headroom: do not keep the face darker than needed
        }
    }
  }
  var target = currentIndex;
  if (stride > 0 && currentIndex > hi) {
    target = max(hi, currentIndex - stride); // e.g. after switching profile: walk back inside its limits
  } else if (stride > 0 && currentIndex < lo) {
    target = min(lo, currentIndex + stride);
  } else if (delta > 0) {
    target = min(currentIndex + delta, hi);
  } else if (delta < 0) {
    target = max(currentIndex + delta, lo);
  }
  return ExposureAdvice(targetIndex: target, warnings: warnings, stopsApart: stopsApart, conflict: conflict);
}
