import 'package:shared_preferences/shared_preferences.dart';

enum CameraFrame {
  full,
  ratio16x9,
  ratio4x3,
  square;

  String get label => switch (this) {
        CameraFrame.full => 'Full',
        CameraFrame.ratio16x9 => '16:9',
        CameraFrame.ratio4x3 => '4:3',
        CameraFrame.square => '1:1',
      };

  /// Returns the actual frame aspect ratio in the current device orientation.
  /// In portrait, a camera's 16:9 frame is 9:16 on screen, and 4:3 is 3:4.
  /// Full means the camera's native sensor/preview ratio with no crop.
  double? ratio(double screenAspect) => switch (this) {
        CameraFrame.full => null,
        CameraFrame.ratio16x9 => screenAspect < 1 ? 9 / 16 : 16 / 9,
        CameraFrame.ratio4x3 => screenAspect < 1 ? 3 / 4 : 4 / 3,
        CameraFrame.square => 1.0,
      };

  static CameraFrame fromName(String? value) => CameraFrame.values.firstWhere(
        (v) => v.name == value,
        orElse: () => CameraFrame.full,
      );
}

class CameraFrameSettings {
  static const key = 'camera.frame';

  static Future<CameraFrame> load() async {
    final p = await SharedPreferences.getInstance();
    return CameraFrame.fromName(p.getString(key));
  }

  static Future<void> save(CameraFrame frame) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, frame.name);
  }
}
