import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/camera_tuning.dart';
import '../../../services/camera_tuning_bridge.dart';
import '../../../services/exposure_meter.dart';
import '../../../services/presentation_exposure.dart';
import '../camera_controller.dart';

/// Drawn on top of the full, un-cropped preview surface (same coordinates as a tap).
class PreviewOverlayPainter extends CustomPainter {
  final FocusMarker? marker;
  final SceneMark? presenterMark;
  final SceneMark? slideMark;
  final MeasuredRegion? detectedFace;
  final MeasuredRegion? estimatedSlide;
  final FrameGeometry? geometry;

  PreviewOverlayPainter({
    this.marker,
    this.presenterMark,
    this.slideMark,
    this.detectedFace,
    this.estimatedSlide,
    this.geometry,
  });

  Rect _rect(NormRect r, Size s) => Rect.fromLTRB(r.left * s.width, r.top * s.height, r.right * s.width, r.bottom * s.height);

  void _box(Canvas canvas, Size size, NormRect r, Color color, String label, {bool dashed = false}) {
    final rect = _rect(r, size);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = dashed ? 1.5 : 2.5
      ..color = color.withValues(alpha: dashed ? .7 : .95);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)), paint);
    final tp = TextPainter(
      text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700, backgroundColor: Colors.black54)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, rect.topLeft + Offset(4, -tp.height - 2 < -rect.top ? 4 : -tp.height - 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final geo = geometry;
    if (geo != null) {
      if (presenterMark == null && detectedFace != null) {
        _box(canvas, size, geo.bufferRectToDisplay(detectedFace!.rect), Colors.lightGreenAccent, 'face (detected)', dashed: true);
      }
      if (slideMark == null && estimatedSlide != null) {
        _box(canvas, size, geo.bufferRectToDisplay(estimatedSlide!.rect), Colors.lightBlueAccent, 'slide (estimated)', dashed: true);
      }
    }
    if (presenterMark != null) _box(canvas, size, presenterMark!.display, Colors.lightGreenAccent, 'presenter');
    if (slideMark != null) _box(canvas, size, slideMark!.display, Colors.lightBlueAccent, 'slide');

    final m = marker;
    if (m != null) {
      final c = Offset(m.x * size.width, m.y * size.height);
      final color = switch (m.state) {
        FocusMarkerState.working => Colors.white,
        FocusMarkerState.focused => Colors.greenAccent,
        FocusMarkerState.metered => Colors.white,
        FocusMarkerState.notConfirmed => AppTheme.amber,
        FocusMarkerState.failed => Colors.redAccent,
      };
      final r = size.shortestSide * 0.09;
      canvas.drawRect(
        Rect.fromCenter(center: c, width: r * 2, height: r * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      final label = m.locked
          ? 'AF·AE LOCK'
          : switch (m.state) {
              FocusMarkerState.working => m.focus ? 'focusing' : 'metering',
              FocusMarkerState.focused => 'focused',
              FocusMarkerState.metered => 'exposure set',
              FocusMarkerState.notConfirmed => 'focus not confirmed',
              FocusMarkerState.failed => 'failed',
            };
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700, backgroundColor: Colors.black45)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c + Offset(-tp.width / 2, r + 4));
    }
  }

  @override
  bool shouldRepaint(PreviewOverlayPainter old) =>
      old.marker != marker ||
      old.presenterMark != presenterMark ||
      old.slideMark != slideMark ||
      old.detectedFace != detectedFace ||
      old.estimatedSlide != estimatedSlide ||
      old.geometry != geometry;
}

/// Compact chips showing what is automatic and what is manual. Tapping opens the controls.
class TuningStatusChips extends StatelessWidget {
  final GeoCameraController controller;
  final VoidCallback onOpen;
  const TuningStatusChips({super.key, required this.controller, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = controller.tuning;
    final caps = controller.capabilities;
    final chips = <Widget>[];
    void add(String text, {bool manual = true}) => chips.add(_Chip(text: text, manual: manual));

    if (controller.presentationMode) {
      chips.add(GestureDetector(
        onTap: controller.cyclePresentationProfile,
        child: _Chip(text: 'PRESENTATION · ${controller.presentationProfile.label}', manual: true, accent: true),
      ));
      if (caps.exposureCompensation && t.evIndex != 0) add('EV ${_ev(caps.evFor(t.evIndex))} auto', manual: false);
    }
    if (t.exposure == ExposureControl.manual) {
      add('ISO ${t.iso} · ${ManualStops.shutterLabel(t.exposureNs)}');
    } else if (!controller.presentationMode && t.evIndex != 0) {
      add('EV ${_ev(caps.evFor(t.evIndex))}');
    }
    if (t.aeLocked) add('AE-L');
    if (t.focus == FocusControl.manual) add('MF ${t.focusDiopters.toStringAsFixed(1)} D');
    if (t.awbMode != Camera2.awbModeAuto) add('WB ${Camera2.awbPresetLabels[t.awbMode] ?? t.awbMode}');
    if (t.awbLocked) add('AWB-L');
    if (chips.isEmpty) add('AUTO', manual: false);

    return GestureDetector(
      onTap: onOpen,
      child: Wrap(spacing: 6, runSpacing: 6, children: chips),
    );
  }

  static String _ev(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';
}

class _Chip extends StatelessWidget {
  final String text;
  final bool manual;
  final bool accent;
  const _Chip({required this.text, required this.manual, this.accent = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: accent ? AppTheme.amber.withValues(alpha: .9) : Colors.black.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: manual && !accent ? AppTheme.amber : Colors.white24),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: accent ? Colors.black : (manual ? AppTheme.amber : Colors.white70),
          ),
        ),
      );
}

/// The most important current warning; tap for all warnings with their measurements.
class SceneWarningBanner extends StatelessWidget {
  final List<SceneWarning> warnings;
  const SceneWarningBanner({super.key, required this.warnings});

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) return const SizedBox.shrink();
    final first = warnings.first;
    return GestureDetector(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppTheme.panel,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Exposure guidance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Measured from the live preview on this phone. The photo can differ slightly.',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 12),
              for (final w in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(w.message, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(w.evidence, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ]),
                ),
            ]),
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wb_iridescent_outlined, size: 16, color: AppTheme.amber),
          const SizedBox(width: 6),
          Flexible(child: Text(first.message, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          if (warnings.length > 1) Text('  +${warnings.length - 1}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ]),
      ),
    );
  }
}
