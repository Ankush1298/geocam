import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../features/camera/camera_page.dart';

class GeoCamApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const GeoCamApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GeoCam',
      theme: AppTheme.dark(),
      home: CameraPage(cameras: cameras),
    );
  }
}
