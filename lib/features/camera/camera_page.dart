import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/stamp_settings.dart';
import '../../models/camera_frame.dart';
import '../../services/presentation_exposure.dart';
import '../capture/result_page.dart';
import '../history/history_page.dart';
import '../scanner/scanner_page.dart';
import '../settings/settings_sheet.dart';
import 'camera_controller.dart';
import 'widgets/camera_controls_sheet.dart';
import 'widgets/camera_overlays.dart';
import 'widgets/location_status_card.dart';

class CameraPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraPage({super.key, required this.cameras});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late final GeoCameraController controller;
  bool _videoMode = false;
  Timer? _recordTimer;
  Timer? _holdStartTimer;
  Duration _recorded = Duration.zero;
  bool _stopRequested = false;
  bool _videoPressActive = false;
  bool _videoPressStarted = false;
  double _videoPressStartY = 0;
  double _videoPressStartZoom = 1.0;
  double _lastShutterZoom = 1.0;
  DateTime? _shutterDownAt;

  @override
  void initState() {
    super.initState();
    controller = GeoCameraController(cameras: widget.cameras)
      ..addListener(_onControllerChanged);
    controller.initialize();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _wasBackgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          controller.onAppResumed();
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wasBackgrounded = true;
        controller.onAppPaused();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Pages pushed over the camera pause preview analysis; settings are re-applied on return.
  /// [releasesCamera]: the page opens the camera itself, so manual settings are lifted meanwhile.
  Future<T?> _pushOverCamera<T>(Route<T> route, {bool releasesCamera = false}) async {
    await controller.setCovered(true, releasesCamera: releasesCamera);
    try {
      if (!mounted) return null;
      return await Navigator.of(context).push(route);
    } finally {
      await controller.setCovered(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _holdStartTimer?.cancel();
    controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final message = controller.message;
    if (message != null) {
      controller.clearMessage();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      });
    }
    setState(() {});
  }

  Future<void> _shootPhoto() async {
    if (controller.position == null) {
      final proceed = await _confirmCapture(
        'No GPS fix',
        'You can still capture the photo, but this record will not have GPS coordinates.',
      );
      if (!proceed) return;
    } else if (controller.position!.accuracy > 100) {
      final proceed = await _confirmCapture(
        'GPS accuracy is weak',
        'Current accuracy is about ±${controller.position!.accuracy.round()} m. Capture anyway?',
      );
      if (!proceed) return;
    }

    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    final result = await controller.capture(
      allowWeakGps: true,
      screenAspect: size.width / size.height,
    );
    if (!mounted || result == null) return;
    await _pushOverCamera(MaterialPageRoute<void>(builder: (_) => ResultPage(result: result)));
  }

  Future<bool> _confirmCapture(String title, String content) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: Text(title),
        content: Text(content, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Capture'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _startVideo() async {
    if (_videoPressStarted || controller.isVideoRecording) return;

    final started = await controller.startVideoRecording();
    if (!mounted) return;

    if (!started) {
      _videoPressStarted = false;
      _videoPressActive = false;
      return;
    }

    _videoPressStarted = true;
    _stopRequested = false;
    _recorded = Duration.zero;
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!mounted || !controller.isVideoRecording) return;
      final startedAt = controller.videoStartedAt;
      if (startedAt != null) {
        setState(() => _recorded = DateTime.now().difference(startedAt));
      }
      if (_recorded >= GeoCameraController.maxVideoDuration && !_stopRequested) {
        _stopRequested = true;
        _videoPressActive = false;
        await _finishVideo();
      }
    });
    setState(() {});
  }

  Future<void> _finishVideo() async {
    if (!controller.isVideoRecording) {
      _videoPressStarted = false;
      return;
    }
    if (_stopRequested && !controller.isVideoRecording) return;
    _stopRequested = true;
    _recordTimer?.cancel();
    _recordTimer = null;
    final result = await controller.stopVideoRecording();
    _videoPressStarted = false;
    _videoPressActive = false;
    _shutterDownAt = null;
    if (!mounted) return;
    setState(() => _recorded = Duration.zero);
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video captured. Saving the location stamp in the background…')),
      );
      result.processedPath.then((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video saved to GeoCam in your phone gallery.')),
        );
      });
    }
  }

  void _onShutterPointerDown(PointerDownEvent event) {
    if (!controller.initialized || controller.busy || !_videoMode) return;

    // If a normal video is already recording, pressing the shutter again
    // means STOP. This is the familiar camera tap-to-start / tap-to-stop mode.
    if (controller.isVideoRecording) {
      _videoPressActive = false;
      _holdStartTimer?.cancel();
      _finishVideo();
      return;
    }

    _videoPressActive = true;
    _videoPressStarted = false;
    _shutterDownAt = DateTime.now();
    _videoPressStartY = event.position.dy;
    _videoPressStartZoom = controller.zoom;
    _lastShutterZoom = controller.zoom;

    // Do not start native recording on pointer-down. That made a normal tap
    // race with pointer-up and could create an instant start/stop clip.
    // A short hold crosses this small threshold and becomes a Snapchat clip.
    _holdStartTimer?.cancel();
    _holdStartTimer = Timer(const Duration(milliseconds: 180), () {
      if (_videoPressActive && !_videoPressStarted && mounted && !controller.isVideoRecording) {
        _startVideo();
      }
    });
  }

  void _onShutterPointerMove(PointerMoveEvent event) {
    if (!_videoMode || !_videoPressActive) return;
    final dy = event.position.dy - _videoPressStartY;

    // A tiny vertical movement is enough to make the intent a drag; recording
    // may still be waiting for the 180ms hold threshold. Once recording starts,
    // the same gesture controls zoom continuously.
    if (!controller.isVideoRecording) return;
    final range = (controller.maxZoom - 1).clamp(1.0, 20.0).toDouble();
    final next = _videoPressStartZoom - (dy / 180.0) * range;
    if ((next - _lastShutterZoom).abs() < 0.03) return;
    _lastShutterZoom = next;
    controller.setZoom(next);
  }

  void _onShutterPointerUp(PointerEvent event) {
    if (!_videoMode) return;
    _holdStartTimer?.cancel();
    _holdStartTimer = null;
    final wasRecording = controller.isVideoRecording;
    final heldFor = _shutterDownAt == null
        ? Duration.zero
        : DateTime.now().difference(_shutterDownAt!);
    _videoPressActive = false;

    if (wasRecording && _videoPressStarted) {
      // Hold-to-record: releasing the finger ends the short clip.
      _finishVideo();
      return;
    }

    // Short tap: start a normal, continuous recording. It remains recording
    // until the user taps the shutter again.
    if (!wasRecording && heldFor < const Duration(milliseconds: 180)) {
      _startVideo();
    }
  }

  void _onShutterPointerCancel(PointerCancelEvent event) {
    if (!_videoMode) return;
    _holdStartTimer?.cancel();
    _holdStartTimer = null;
    _videoPressActive = false;
    // Only stop when a real hold recording had already started. A cancelled
    // pre-start gesture must not create a recording.
    if (_videoPressStarted && controller.isVideoRecording && !_stopRequested) {
      _finishVideo();
    }
  }

  void _onShutterTapUp() {
    if (_videoMode || !controller.initialized || controller.busy) return;
    _shootPhoto();
  }

  void _onPreviewPointerDown(PointerDownEvent event) {}

  void _onPreviewPointerMove(PointerMoveEvent event) {
    if (!controller.initialized || controller.isVideoRecording) return;
    final dy = event.delta.dy;
    if (dy.abs() < 1.0) return;
    final range = (controller.maxZoom - 1).clamp(1.0, 20.0).toDouble();
    controller.setZoom(controller.zoom - dy / 220.0 * range);
  }

  Future<void> _openFramePicker() async {
    final selected = await showModalBottomSheet<CameraFrame>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Frame', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 6),
            const Text('Choose the framing used by the live preview and final photo.', style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: CameraFrame.values.map((option) {
                return ChoiceChip(
                  label: Text(option.label),
                  selected: controller.frame == option,
                  onSelected: (_) => Navigator.pop(ctx, option),
                );
              }).toList(),
            ),
          ]),
        ),
      ),
    );
    if (selected != null) await controller.setFrame(selected);
  }

  Future<void> _openSettings() async {
    final result = await showModalBottomSheet<StampSettings>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.panel,
      builder: (_) => SettingsSheet(initial: controller.settings),
    );
    if (result != null) await controller.saveSettings(result);
  }

  void _openHistory() => _pushOverCamera(MaterialPageRoute<void>(builder: (_) => const HistoryPage()));
  void _openScanner() =>
      _pushOverCamera(MaterialPageRoute<void>(builder: (_) => const ScannerPage()), releasesCamera: true);

  void _openCameraControls() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: AppTheme.panel,
        barrierColor: Colors.black26,
        builder: (_) => CameraControlsSheet(controller: controller),
      );

  void _setVideoMode(bool video) {
    setState(() => _videoMode = video);
    controller.setVideoMode(video);
  }

  void _onPreviewTapUp(Offset local, Size size, {bool lock = false}) {
    if (size.isEmpty) return;
    controller.onPreviewTap(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
      lock: lock,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller.camera;
    final ready = controller.initialized && c != null && c.value.isInitialized;
    final recording = controller.isVideoRecording;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: ready
                ? Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _onPreviewPointerDown,
                    onPointerMove: _onPreviewPointerMove,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final screenAspect = constraints.maxWidth / constraints.maxHeight;
                      final camAspect = c.value.previewSize != null
                          ? c.value.previewSize!.height / c.value.previewSize!.width
                          : screenAspect;
                      final targetAspect = controller.frameRatio(screenAspect);
                      return Center(
                        child: AspectRatio(
                          aspectRatio: targetAspect,
                          child: ClipRect(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: constraints.maxWidth,
                                height: constraints.maxWidth / camAspect,
                                // The overlay and the tap layer cover the whole, un-cropped preview
                                // surface, so tap coordinates are what the camera expects.
                                child: Stack(fit: StackFit.expand, children: [
                                  CameraPreview(c),
                                  Builder(builder: (context) {
                                    final surface = Size(constraints.maxWidth, constraints.maxWidth / camAspect);
                                    final m = controller.presentationMode ? controller.lastMeasurement : null;
                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTapUp: (d) => _onPreviewTapUp(d.localPosition, surface),
                                      onLongPressStart: (d) => _onPreviewTapUp(d.localPosition, surface, lock: true),
                                      child: CustomPaint(
                                        painter: PreviewOverlayPainter(
                                          marker: controller.focusMarker,
                                          presenterMark: controller.presentationMode ? controller.presenterMark : null,
                                          slideMark: controller.presentationMode ? controller.slideMark : null,
                                          detectedFace: m?.presenter?.source == RegionSource.detectedFace ? m!.presenter : null,
                                          estimatedSlide: m?.slide?.source == RegionSource.estimatedScreen ? m!.slide : null,
                                          geometry: controller.lastGeometry,
                                        ),
                                      ),
                                    );
                                  }),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  )
                : const Center(child: CircularProgressIndicator(color: AppTheme.amber)),
          ),
          if (recording)
            Positioned(
              top: 18,
              left: 0,
              right: 0,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.red.withValues(alpha: .9), borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    child: Text('● ${_formatDuration(_recorded)}  •  release to stop', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            )
          else
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .65), borderRadius: BorderRadius.circular(22)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.location_on, color: AppTheme.amber, size: 18),
                    SizedBox(width: 6),
                    Text('GeoCam', style: TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
                const Spacer(),
                _TopButton(icon: Icons.qr_code_scanner, tooltip: 'Scan / Verify QR', onPressed: _openScanner),
                _TopButton(icon: Icons.tune, tooltip: 'Stamp settings', onPressed: _openSettings),
                _TopButton(icon: controller.flashOn ? Icons.flash_on : Icons.flash_off, tooltip: 'Flash', onPressed: ready ? controller.toggleFlash : null),
                _TopButton(icon: Icons.crop_free, tooltip: 'Frame', onPressed: ready ? _openFramePicker : null),
              ]),
            ),
          if (!recording && ready)
            Positioned(
              top: 70,
              left: 12,
              right: 70,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  GestureDetector(
                    onTap: _openCameraControls,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(14)),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.camera_outlined, size: 14),
                        SizedBox(width: 4),
                        Text('Controls', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
                  Expanded(child: TuningStatusChips(controller: controller, onOpen: _openCameraControls)),
                ]),
                if (controller.armedMark != MarkTarget.none)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InputChip(
                      label: Text(controller.armedMark == MarkTarget.presenter
                          ? 'Tap the presenter on the preview'
                          : 'Tap the slide on the preview'),
                      onDeleted: () => controller.armMark(MarkTarget.none),
                    ),
                  )
                else if (controller.sceneWarnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SceneWarningBanner(warnings: controller.sceneWarnings),
                  ),
              ]),
            ),
          if (!recording)
            Positioned(
              top: 74,
              right: 14,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: controller.zoom > 1.01 ? 1 : .72,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), borderRadius: BorderRadius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('${controller.zoom.toStringAsFixed(1)}×', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 154,
            child: GestureDetector(
              onTap: () => showModalBottomSheet<void>(
                context: context,
                backgroundColor: AppTheme.panel,
                builder: (_) => SafeArea(child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(controller.locationStatus),
                )),
              ),
              child: LocationStatusCard(
                position: controller.position,
                address: controller.address,
                status: controller.locationStatus,
              ),
            ),
          ),
          if (controller.position == null && !recording)
            Positioned(
              left: 12,
              right: 12,
              bottom: 104,
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: controller.locationLoading ? null : controller.retryLocation,
                  icon: controller.locationLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location, size: 17),
                  label: Text(controller.locationLoading ? 'Finding GPS…' : 'Retry GPS'),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: .02), Colors.black.withValues(alpha: .94)],
                ),
              ),
              child: Column(children: [
                // Normal-camera style mode selector: directly above shutter.
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .58), borderRadius: BorderRadius.circular(24)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ModeButton(label: 'PHOTO', active: !_videoMode, onTap: recording ? null : () => _setVideoMode(false)),
                    _ModeButton(label: 'VIDEO', active: _videoMode, onTap: recording ? null : () => _setVideoMode(true)),
                  ]),
                ),
                const SizedBox(height: 10),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  IconButton(
                    tooltip: 'Switch camera',
                    iconSize: 30,
                    onPressed: !controller.busy ? controller.switchCamera : null,
                    icon: const Icon(Icons.flip_camera_android),
                  ),
                  Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _videoMode ? _onShutterPointerDown : null,
                    onPointerMove: _videoMode ? _onShutterPointerMove : null,
                    onPointerUp: _videoMode ? _onShutterPointerUp : null,
                    onPointerCancel: _videoMode ? _onShutterPointerCancel : null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _videoMode ? null : _onShutterTapUp,
                      child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: recording ? 82 : 76,
                      height: recording ? 82 : 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: recording ? Colors.red : Colors.white,
                        border: Border.all(color: Colors.black.withValues(alpha: .85), width: 5),
                        boxShadow: const [BoxShadow(color: Colors.white24, spreadRadius: 3)],
                      ),
                      child: recording
                          ? const Center(child: Icon(Icons.stop_rounded, color: Colors.white, size: 34))
                          : (_videoMode ? const Center(child: Icon(Icons.videocam, color: Colors.black87, size: 28)) : null),
                      ),
                    ),
                  ),
                  IconButton(tooltip: 'Gallery', iconSize: 30, onPressed: _openHistory, icon: const Icon(Icons.collections_outlined)),
                ]),
                if (_videoMode && !recording)
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text('Tap to start/stop • hold to make a short clip • slide up/down to zoom', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final seconds = d.inSeconds;
    final tenths = (d.inMilliseconds % 1000) ~/ 100;
    return '00:${seconds.toString().padLeft(2, '0')}.$tenths';
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;
  const _ModeButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(color: active ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(18)),
        child: Text(label, style: TextStyle(color: active ? Colors.black : Colors.white70, fontWeight: FontWeight.w800, fontSize: 12)),
      ),
    );
  }
}

class _TopButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _TopButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: .65)),
      icon: Icon(icon),
    );
  }
}
