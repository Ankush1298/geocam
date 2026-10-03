import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'app/geocam_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = <CameraDescription>[];
  try {
    cameras = await availableCameras();
  } catch (_) {
    // The app can still launch and show a useful error state.
  }

  runApp(GeoCamApp(cameras: cameras));
}
