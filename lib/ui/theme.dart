import 'package:flutter/material.dart';

class AppTheme {
  static const Color bg = Color(0xFF080B14);
  static const Color surface = Color(0xFF0F1420);
  static const Color card = Color(0xFF151C2C);
  static const Color border = Color(0xFF1E2A40);
  static const Color cyan = Color(0xFF00E5FF);
  static const Color cyanDim = Color(0xFF0097A7);
  static const Color purple = Color(0xFF7C4DFF);
  static const Color green = Color(0xFF00E676);
  static const Color orange = Color(0xFFFF6D00);
  static const Color textPrimary = Color(0xFFECEFF1);
  static const Color textSecondary = Color(0xFF78909C);
  static const Color textMuted = Color(0xFF37474F);

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: purple,
        surface: surface,
        background: bg,
      ),
      fontFamily: 'monospace',
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cyan,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cyan, width: 1.5),
        ),
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textMuted),
      ),
    );
  }
}
