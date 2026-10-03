import 'package:flutter/material.dart';

class AppTheme {
  static const amber = Color(0xFFFFB020);
  static const panel = Color(0xFF17191C);

  static ThemeData dark() {
    return ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: Colors.black,
      colorScheme: ColorScheme.fromSeed(
        seedColor: amber,
        brightness: Brightness.dark,
      ),
    );
  }
}
