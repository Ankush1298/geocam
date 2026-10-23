import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/camera/camera_controller.dart';
import 'package:geocam/features/camera/widgets/camera_controls_sheet.dart';
import 'package:geocam/services/camera_tuning_bridge.dart';

import 'camera_tuning_test.dart' show basicCaps, fullCaps;

Future<GeoCameraController> pumpSheet(WidgetTester tester, CameraCapabilities caps, {bool video = false}) async {
  final c = GeoCameraController(cameras: const [])
    ..capabilities = caps
    ..videoModeActive = video;
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(body: CameraControlsSheet(controller: c)),
  ));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('no reported controls: explains instead of showing dead controls', (tester) async {
    await pumpSheet(tester, CameraCapabilities.none);
    expect(find.textContaining('does not report adjustable controls'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Manual ISO/shutter'), findsNothing);
    expect(find.text('Run camera control check'), findsNothing);
    // Presentation Mode can still give guidance.
    expect(find.text('Presentation Mode'), findsOneWidget);
  });

  testWidgets('basic camera: exposure compensation only, no manual modes or presets', (tester) async {
    await pumpSheet(tester, basicCaps);
    expect(find.textContaining('Exposure +0.0 EV'), findsOneWidget);
    expect(find.text('Manual ISO/shutter'), findsNothing);
    expect(find.widgetWithText(ButtonSegment<Object>, 'Manual'), findsNothing);
    expect(find.text('Lock exposure'), findsNothing, reason: 'AE lock is not reported');
    expect(find.text('Daylight'), findsNothing);
    expect(find.textContaining('only offers automatic white balance'), findsOneWidget);
    expect(find.textContaining('Tap the preview to focus'), findsOneWidget);
  });

  testWidgets('full camera: manual modes and exactly the reported presets', (tester) async {
    await pumpSheet(tester, fullCaps);
    expect(find.text('Manual ISO/shutter'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget, reason: 'manual focus segment');
    expect(find.text('Lock exposure'), findsOneWidget);
    expect(find.text('Lock white balance'), findsOneWidget);
    for (final label in ['Daylight', 'Cloudy', 'Incandescent', 'Fluorescent']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Shade'), findsNothing, reason: 'not reported by this camera');
    expect(find.text('Twilight'), findsNothing);
  });

  testWidgets('all sections show AUTO by default', (tester) async {
    await pumpSheet(tester, fullCaps);
    expect(find.text('AUTO'), findsNWidgets(3));
    expect(find.text('MANUAL'), findsNothing);
  });

  testWidgets('video mode does not offer manual ISO/shutter or Presentation Mode', (tester) async {
    await pumpSheet(tester, fullCaps, video: true);
    expect(find.text('Manual ISO/shutter is for photos only.'), findsOneWidget);
    expect(find.text('Available in photo mode.'), findsOneWidget);
  });
}
