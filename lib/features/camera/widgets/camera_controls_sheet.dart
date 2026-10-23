import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/camera_tuning.dart';
import '../../../services/camera_tuning_bridge.dart';
import '../../../services/presentation_exposure.dart';
import '../camera_controller.dart';

/// Exposure, focus, white balance and Presentation Mode. Only controls the active camera reports
/// are shown; everything else is explained instead of being offered as a dead control.
class CameraControlsSheet extends StatelessWidget {
  final GeoCameraController controller;
  const CameraControlsSheet({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .5,
      minChildSize: .25,
      maxChildSize: .9,
      builder: (context, scroll) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: _sections(context),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final c = controller;
    final caps = c.capabilities;
    final t = c.tuning;
    final none = caps == CameraCapabilities.none;
    return [
      Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
      ),
      Row(children: [
        const Expanded(
          child: Text('Camera controls',
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        TextButton.icon(
          onPressed: t.isAllAuto ? null : c.resetAllTuning,
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('All auto'),
        ),
      ]),
      if (none)
        const _Note('This camera does not report adjustable controls, or they are unavailable right now. '
            'Photos still capture normally in automatic mode.'),
      if (!none) ...[
        _exposure(context, caps, t),
        _focus(caps, t),
        _whiteBalance(caps, t),
      ],
      const Divider(height: 28),
      _presentation(context, caps),
      const Divider(height: 28),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Exposure warnings'),
        subtitle: const Text('Warns about clipped highlights and dark scenes, measured from the live preview.'),
        value: c.exposureWarnings,
        onChanged: c.setExposureWarnings,
      ),
      if (!none) ...[
        const SizedBox(height: 8),
        Text(
          'Camera: ${caps.hardwareLevel} hardware level · manual sensor ${caps.manualSensor ? 'yes' : 'no'}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _runCheck(context),
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('Run camera control check'),
          ),
        ),
      ],
    ];
  }

  // ------------------------------------------------------------------ exposure

  Widget _exposure(BuildContext context, CameraCapabilities caps, CameraTuning t) {
    final c = controller;
    final manualAllowed = caps.manualExposure && !c.videoModeActive && !c.presentationMode;
    final children = <Widget>[];
    children.add(_Header('Exposure', auto: t.exposureIsAuto, onReset: t.exposureIsAuto ? null : () => c.applyTuning(t.resetExposure())));
    if (caps.manualExposure || t.exposure == ExposureControl.manual) {
      children.add(SegmentedButton<ExposureControl>(
        segments: const [
          ButtonSegment(value: ExposureControl.auto, label: Text('Auto')),
          ButtonSegment(value: ExposureControl.manual, label: Text('Manual ISO/shutter')),
        ],
        selected: {t.exposure},
        onSelectionChanged: (s) {
          if (s.first == ExposureControl.manual && !manualAllowed) return;
          c.applyTuning(t.copyWith(exposure: s.first, aeLocked: false));
        },
      ));
      if (!manualAllowed && t.exposure == ExposureControl.auto) {
        children.add(_Note(c.videoModeActive
            ? 'Manual ISO/shutter is for photos only.'
            : c.presentationMode
                ? 'Presentation Mode controls exposure automatically.'
                : ''));
      }
    }
    if (t.exposure == ExposureControl.manual) {
      final isoStops = ManualStops.iso(caps.isoRange!);
      final shutterStops = ManualStops.shutterNs(caps.exposureTimeRangeNs!);
      final isoI = ManualStops.nearest(isoStops, t.iso);
      final shI = ManualStops.nearest(shutterStops, t.exposureNs);
      children.addAll([
        _SliderRow(
          label: 'ISO ${isoStops[isoI]}',
          value: isoI.toDouble(),
          max: (isoStops.length - 1).toDouble(),
          onChanged: (v) => c.applyTuning(t.copyWith(iso: isoStops[v.round()])),
        ),
        _SliderRow(
          label: 'Shutter ${ManualStops.shutterLabel(shutterStops[shI])}',
          value: shI.toDouble(),
          max: (shutterStops.length - 1).toDouble(),
          onChanged: (v) => c.applyTuning(t.copyWith(exposureNs: shutterStops[v.round()])),
        ),
        const _Note('Exposure is fixed: the preview shows how bright the photo will be. Slow shutter speeds blur handheld shots.'),
      ]);
    } else {
      if (caps.exposureCompensation) {
        final ev = caps.evFor(t.evIndex);
        children.add(_SliderRow(
          label: 'Exposure ${ev >= 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV',
          value: t.evIndex.toDouble(),
          min: caps.aeCompensationMin.toDouble(),
          max: caps.aeCompensationMax.toDouble(),
          onChanged: c.presentationMode ? null : (v) => c.applyTuning(t.copyWith(evIndex: v.round())),
        ));
        if (c.presentationMode) children.add(const _Note('Adjusted by the presentation profile.'));
      } else {
        children.add(const _Note('This camera does not support exposure compensation.'));
      }
      if (caps.aeLockAvailable && !c.presentationMode) {
        children.add(SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Lock exposure'),
          value: t.aeLocked,
          onChanged: (v) => c.applyTuning(t.copyWith(aeLocked: v)),
        ));
      }
      if (caps.tapToMeter && !c.presentationMode) {
        children.add(const _Note('Tap the preview to set exposure for that spot (spot metering).'));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  // ------------------------------------------------------------------ focus

  Widget _focus(CameraCapabilities caps, CameraTuning t) {
    final c = controller;
    final children = <Widget>[
      _Header('Focus', auto: t.focusIsAuto && c.focusMarker?.locked != true, onReset: t.focusIsAuto && c.focusMarker?.locked != true
          ? null
          : () async {
              await c.cancelFocusLock();
              await c.applyTuning(t.resetFocus());
            }),
    ];
    if (!caps.autofocus && !caps.manualFocus) {
      children.add(const _Note('This camera has fixed focus.'));
    } else {
      if (caps.manualFocus) {
        children.add(SegmentedButton<FocusControl>(
          segments: const [
            ButtonSegment(value: FocusControl.auto, label: Text('Auto')),
            ButtonSegment(value: FocusControl.manual, label: Text('Manual')),
          ],
          selected: {t.focus},
          onSelectionChanged: (s) => c.applyTuning(t.copyWith(focus: s.first)),
        ));
      }
      if (t.focus == FocusControl.manual) {
        children.add(_SliderRow(
          label: t.focusDiopters <= 0.05 ? 'Focus: far (∞)' : 'Focus: ${(1 / t.focusDiopters).toStringAsFixed(2)} m (approx.)',
          value: t.focusDiopters,
          max: caps.minFocusDistance,
          stepped: false,
          onChanged: (v) => c.applyTuning(t.copyWith(focusDiopters: v)),
        ));
        children.add(const _Note('Distances are approximate unless the lens is calibrated.'));
      } else if (caps.tapToFocus) {
        children.add(const _Note('Continuous autofocus. Tap the preview to focus there; long-press to lock focus and metering on that point.'));
      } else {
        children.add(const _Note('Continuous autofocus. This camera does not support tap-to-focus.'));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  // ------------------------------------------------------------------ white balance

  Widget _whiteBalance(CameraCapabilities caps, CameraTuning t) {
    final c = controller;
    final presets = caps.whiteBalancePresets;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Header('White balance', auto: t.whiteBalanceIsAuto, onReset: t.whiteBalanceIsAuto ? null : () => c.applyTuning(t.resetWhiteBalance())),
      if (presets.isEmpty)
        const _Note('This camera only offers automatic white balance.')
      else
        Wrap(spacing: 6, runSpacing: 6, children: [
          ChoiceChip(
            label: const Text('Auto'),
            selected: t.awbMode == Camera2.awbModeAuto,
            onSelected: (_) => c.applyTuning(t.copyWith(awbMode: Camera2.awbModeAuto)),
          ),
          for (final p in presets)
            ChoiceChip(
              label: Text(Camera2.awbPresetLabels[p]!),
              selected: t.awbMode == p,
              onSelected: (_) => c.applyTuning(t.copyWith(awbMode: p)),
            ),
        ]),
      if (caps.awbLockAvailable)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Lock white balance'),
          value: t.awbLocked,
          onChanged: (v) => c.applyTuning(t.copyWith(awbLocked: v)),
        ),
      const _Note('A colour-temperature (Kelvin) slider is not offered: Android cameras do not expose a portable Kelvin control.'),
    ]);
  }

  // ------------------------------------------------------------------ presentation

  Widget _presentation(BuildContext context, CameraCapabilities caps) {
    final c = controller;
    final advice = c.lastAdvice;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Presentation Mode', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(c.videoModeActive
            ? 'Available in photo mode.'
            : 'For a presenter next to a bright projector or screen. Exposure is adjusted from live measurements.'),
        value: c.presentationMode,
        onChanged: c.videoModeActive ? null : c.setPresentationMode,
      ),
      if (c.presentationMode) ...[
        if (!caps.exposureCompensation)
          const _Note('This camera cannot adjust exposure compensation, so Presentation Mode can only give guidance.'),
        for (final p in PresentationProfile.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            onTap: () => c.setPresentationProfile(p),
            leading: Icon(
              c.presentationProfile == p ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: c.presentationProfile == p ? AppTheme.amber : Colors.white54,
            ),
            title: Text(p.label + (p == PresentationProfile.balanced ? ' (default)' : '')),
            subtitle: Text(p.description, style: const TextStyle(fontSize: 12)),
          ),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          FilterChip(
            avatar: const Icon(Icons.person_outline, size: 18),
            label: Text(c.presenterMark == null ? 'Mark presenter' : 'Re-mark presenter'),
            selected: c.armedMark == MarkTarget.presenter,
            onSelected: (_) {
              c.armMark(MarkTarget.presenter);
              Navigator.of(context).maybePop();
            },
          ),
          FilterChip(
            avatar: const Icon(Icons.slideshow_outlined, size: 18),
            label: Text(c.slideMark == null ? 'Mark slide' : 'Re-mark slide'),
            selected: c.armedMark == MarkTarget.slide,
            onSelected: (_) {
              c.armMark(MarkTarget.slide);
              Navigator.of(context).maybePop();
            },
          ),
          if (c.presenterMark != null || c.slideMark != null)
            ActionChip(label: const Text('Clear marks'), onPressed: c.clearMarks),
        ]),
        _Note(_measurementSummary(c, advice)),
        const _Note('Faces are found on this phone with ML Kit. No frames, face data or measurements are uploaded '
            'or saved, and nothing from this analysis goes into the GeoCam record. Nobody is identified.'),
        const _Note('One exposure cannot always hold both a bright projector and a face. If guidance says the '
            'difference is too large, change the angle, dim lights near the screen, or light the presenter.'),
      ],
    ]);
  }

  String _measurementSummary(GeoCameraController c, ExposureAdvice? advice) {
    final m = c.lastMeasurement;
    if (m == null) return 'Measuring…';
    final parts = <String>[];
    final p = m.presenter;
    if (p != null) {
      parts.add('${p.source == RegionSource.detectedFace ? 'Face detected' : 'Presenter marked'}: '
          'brightness ${p.stats.mean.round()}/255');
    } else {
      parts.add('No face found');
    }
    final s = m.slide;
    if (s != null) {
      parts.add('${s.source == RegionSource.estimatedScreen ? 'Slide (estimated)' : 'Slide marked'}: '
          '${(s.stats.clipped * 100).round()}% clipped');
    } else {
      parts.add('No slide found');
    }
    if (advice?.stopsApart != null) parts.add('about ${advice!.stopsApart!.toStringAsFixed(1)} stops apart');
    return '${parts.join(' · ')} (from the live preview)';
  }

  // ------------------------------------------------------------------ control check

  Future<void> _runCheck(BuildContext context) async {
    final messenger = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: AppTheme.panel,
        content: Row(children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 14),
          Expanded(child: Text('Checking camera controls… Watch the preview: it should get brighter, then darker.')),
        ]),
      ),
    );
    final steps = await controller.runControlCheck();
    if (!messenger.mounted) return;
    messenger.pop();
    await showDialog<void>(
      context: messenger.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('Camera control check'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    s.passed == null ? Icons.remove_circle_outline : (s.passed! ? Icons.check_circle : Icons.cancel),
                    color: s.passed == null ? Colors.white38 : (s.passed! ? Colors.greenAccent : Colors.redAccent),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(s.detail, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            const Text('Please also note whether the preview visibly changed brightness.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final bool auto;
  final VoidCallback? onReset;
  const _Header(this.title, {required this.auto, this.onReset});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Row(children: [
          Flexible(
            child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: auto ? Colors.white10 : AppTheme.amber.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(auto ? 'AUTO' : 'MANUAL',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: auto ? Colors.white60 : AppTheme.amber)),
          ),
          const Spacer(),
          if (onReset != null) TextButton(onPressed: onReset, child: const Text('Auto')),
        ]),
      );
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  /// Snap to whole steps (exposure index, ISO/shutter stop). Focus distance is continuous.
  final bool stepped;
  const _SliderRow({
    required this.label,
    required this.value,
    this.min = 0,
    required this.max,
    this.onChanged,
    this.stepped = true,
  });

  @override
  Widget build(BuildContext context) {
    final divisions = stepped ? (max - min).round() : 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 13)),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max <= min ? min + 1 : max,
        divisions: divisions > 0 && divisions <= 200 ? divisions : null,
        onChanged: max <= min ? null : onChanged,
      ),
    ]);
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => text.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        );
}
