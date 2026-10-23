import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/services/exposure_meter.dart';
import 'package:geocam/services/presentation_exposure.dart';
import 'package:geocam/services/scene_analyzer.dart';

RegionStats stats({double mean = 120, double clipped = 0, int p95 = 200}) =>
    RegionStats(mean: mean, p05: 10, p50: mean.round(), p95: p95, clipped: clipped, dark: 0, samples: 1000);

const _face = NormRect(0.1, 0.3, 0.2, 0.45);
const _slide = NormRect(0.4, 0.2, 0.9, 0.6);

SceneMeasurement measure({RegionStats? face, RegionStats? slide, RegionSource faceSource = RegionSource.detectedFace}) =>
    SceneMeasurement(
      global: stats(),
      presenter: face == null ? null : MeasuredRegion(_face, face, faceSource),
      slide: slide == null ? null : MeasuredRegion(_slide, slide, RegionSource.estimatedScreen),
    );

ExposureAdvice advise(PresentationProfile p, SceneMeasurement m, {int current = 0, double step = 1 / 6, int minI = -12, int maxI = 12}) =>
    advisePresentation(profile: p, m: m, currentIndex: current, minIndex: minI, maxIndex: maxI, step: step);

Set<SceneWarningKind> kinds(ExposureAdvice a) => a.warnings.map((w) => w.kind).toSet();

void main() {
  group('Balanced (default)', () {
    test('brightens a dark face when the slide has headroom', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 50), slide: stats(clipped: 0.0)));
      expect(a.targetIndex, 2, reason: '1/3 EV with 1/6 EV steps');
      expect(kinds(a), contains(SceneWarningKind.faceTooDark));
    });

    test('darkens a clipped slide when the face is comfortably exposed', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 130), slide: stats(clipped: 0.3, p95: 255)));
      expect(a.targetIndex, -2);
      expect(kinds(a), contains(SceneWarningKind.slideClipped));
    });

    test('holds and explains when face and slide cannot both be fixed', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 40), slide: stats(mean: 250, clipped: 0.4, p95: 255)),
          current: 3);
      expect(a.conflict, isTrue);
      expect(a.targetIndex, 3, reason: 'no step either way can fix both');
      expect(kinds(a), containsAll([SceneWarningKind.faceTooDark, SceneWarningKind.slideClipped, SceneWarningKind.rangeExceeded]));
      expect(a.stopsApart, greaterThan(3));
    });

    test('holds when both are fine', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 120), slide: stats(clipped: 0.0)), current: 1);
      expect(a.targetIndex, 1);
      expect(a.warnings, isEmpty);
    });

    test('with nothing found it holds and asks the user to tap', () {
      final a = advise(PresentationProfile.balanced, measure(), current: -1);
      expect(a.targetIndex, -1);
      expect(kinds(a), {SceneWarningKind.tapToMark});
    });

    test('stays inside its +1.5 EV limit', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 30), slide: stats()), current: 9);
      expect(a.targetIndex, 9, reason: '+1.5 EV = index 9 at 1/6 EV');
    });
  });

  group('Face priority', () {
    test('brightens the face while slide clipping is moderate', () {
      final a = advise(PresentationProfile.facePriority, measure(face: stats(mean: 50), slide: stats(clipped: 0.1, p95: 255)));
      expect(a.targetIndex, 2);
    });

    test('pulls back and suggests Balanced when it clips most of the slide', () {
      final a = advise(PresentationProfile.facePriority, measure(face: stats(mean: 110), slide: stats(clipped: 0.35, p95: 255)),
          current: 6);
      expect(a.targetIndex, 4);
      expect(kinds(a), contains(SceneWarningKind.tryBalanced));
    });
  });

  group('conflict (face too dark and slide clipped)', () {
    final m = measure(face: stats(mean: 40), slide: stats(mean: 250, clipped: 0.12, p95: 255));
    test('Face priority still brightens the presenter', () {
      final a = advise(PresentationProfile.facePriority, m);
      expect(a.conflict, isTrue);
      expect(a.targetIndex, 2);
    });
    test('Slide priority still protects the slide', () {
      final a = advise(PresentationProfile.slidePriority, m);
      expect(a.targetIndex, -2);
    });
    test('all profiles explain the limit', () {
      for (final p in PresentationProfile.values) {
        expect(kinds(advise(p, m)), contains(SceneWarningKind.rangeExceeded), reason: p.name);
      }
    });
  });

  group('Slide priority', () {
    test('darkens until the slide is not clipped', () {
      final a = advise(PresentationProfile.slidePriority, measure(face: stats(mean: 100), slide: stats(clipped: 0.08, p95: 255)));
      expect(a.targetIndex, -2);
    });

    test('does not keep the face darker than needed when the slide has headroom', () {
      final a = advise(PresentationProfile.slidePriority, measure(face: stats(mean: 45), slide: stats(clipped: 0, p95: 200)),
          current: -6);
      expect(a.targetIndex, -4);
      expect(kinds(a), contains(SceneWarningKind.tryBalanced));
    });

    test('can go down to -2.5 EV', () {
      final a = advise(PresentationProfile.slidePriority, measure(slide: stats(clipped: 0.5, p95: 255)), current: -14, minI: -24);
      expect(a.targetIndex, -15, reason: '-2.5 EV = index -15 at 1/6 EV');
    });
  });

  group('limits', () {
    test('never leaves the camera range', () {
      final a = advise(PresentationProfile.facePriority, measure(face: stats(mean: 20), slide: stats()), current: 4, maxI: 4);
      expect(a.targetIndex, 4);
    });

    test('step size: 1/2 EV steps move one index', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 50), slide: stats()), step: 0.5);
      expect(a.targetIndex, 1);
    });

    test('after a profile switch, exposure walks back inside the new limits', () {
      // Face priority had reached +2 EV (index 12); Slide priority allows +1 EV (index 6).
      final a = advise(PresentationProfile.slidePriority, measure(face: stats(mean: 120), slide: stats()), current: 12);
      expect(a.targetIndex, 10);
    });

    test('no exposure compensation: guidance only, never a change', () {
      final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 40), slide: stats()), step: 0, minI: 0, maxI: 0);
      expect(a.targetIndex, 0);
      expect(kinds(a), contains(SceneWarningKind.faceTooDark));
    });
  });

  test('warnings carry the measurement they are based on', () {
    final a = advise(PresentationProfile.balanced, measure(face: stats(mean: 50.4), slide: stats(clipped: 0.123, p95: 255)));
    final face = a.warnings.firstWhere((w) => w.kind == SceneWarningKind.faceTooDark);
    expect(face.message, 'Face may be too dark.');
    expect(face.evidence, contains('50/255'));
    expect(face.evidence, contains('detected face'));
    final slide = a.warnings.firstWhere((w) => w.kind == SceneWarningKind.slideClipped);
    expect(slide.message, 'Slide highlights may be clipped.');
    expect(slide.evidence, contains('12%'));
    expect(slide.evidence, contains('estimated'));
  });

  group('frame warnings', () {
    test('clipped highlights', () {
      expect(frameWarnings(stats(clipped: 0.06)).single.kind, SceneWarningKind.highlightsClipped);
    });
    test('underexposed', () {
      expect(frameWarnings(stats(mean: 30, p95: 90)).single.kind, SceneWarningKind.underexposed);
    });
    test('a normal scene has no warnings', () {
      expect(frameWarnings(stats()), isEmpty);
    });
  });

  group('buildMeasurement', () {
    LumaGrid grid() {
      const w = 160, h = 120;
      final v = Uint8List(w * h)..fillRange(0, w * h, 60);
      for (var y = 24; y < 72; y++) {
        for (var x = 72; x < 152; x++) {
          v[y * w + x] = 253; // slide
        }
      }
      for (var y = 40; y < 52; y++) {
        for (var x = 20; x < 32; x++) {
          v[y * w + x] = 70; // face
        }
      }
      return LumaGrid(w, h, v);
    }

    test('uses the detected face and the estimated screen', () {
      final f = SceneFrame(grid(), const FrameGeometry(rotation: 0), const [NormRect(0.115, 0.32, 0.21, 0.45)]);
      final m = buildMeasurement(f);
      expect(m.presenter!.source, RegionSource.detectedFace);
      expect(m.presenter!.stats.mean, closeTo(70, 1));
      expect(m.slide!.source, RegionSource.estimatedScreen);
      expect(m.slide!.stats.clipped, greaterThan(0.9));
    });

    test("the user's marks win over detection", () {
      final f = SceneFrame(grid(), const FrameGeometry(rotation: 0), const [NormRect(0.115, 0.32, 0.21, 0.45)]);
      final m = buildMeasurement(f, presenterMark: const NormRect(0, 0, 0.1, 0.1), slideMark: const NormRect(0, 0.9, 0.2, 1));
      expect(m.presenter!.source, RegionSource.markedPresenter);
      expect(m.presenter!.stats.mean, closeTo(60, 1));
      expect(m.slide!.source, RegionSource.markedSlide);
      expect(m.slide!.stats.clipped, 0);
    });

    test('no face and no screen leaves both empty', () {
      const w = 40, h = 30;
      final f = SceneFrame(LumaGrid(w, h, Uint8List(w * h)..fillRange(0, w * h, 100)), const FrameGeometry(rotation: 0), const []);
      final m = buildMeasurement(f);
      expect(m.presenter, isNull);
      expect(m.slide, isNull);
    });
  });
}
