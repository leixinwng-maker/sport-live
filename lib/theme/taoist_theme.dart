import 'package:flutter/material.dart';

/// 道家风格主题
/// 以黑、白、青为主色调，体现道家"大道至简"的理念
class TaoistTheme {
  // 颜色定义
  static const Color inkBlack = Color(0xFF1A1A1A); // 墨黑
  static const Color paperWhite = Color(0xFFFAF8F4); // 宣纸白
  static const Color jadeGreen = Color(0xFF4A7C59); // 玉青
  static const Color bambooGreen = Color(0xFF6B8E6F); // 竹绿
  static const Color teaBrown = Color(0xFF8B6F47); // 茶褐
  static const Color cloudGray = Color(0xFF8A8A8A); // 云灰
  static const Color mistGray = Color(0xFFE8E4DC); // 雾灰

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: jadeGreen,
      primary: jadeGreen,
      secondary: teaBrown,
      surface: paperWhite,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: paperWhite,
      fontFamily: 'serif',
      appBarTheme: const AppBarTheme(
        backgroundColor: paperWhite,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: inkBlack,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: 'serif',
        ),
        iconTheme: IconThemeData(color: inkBlack),
      ),
      cardTheme: CardThemeData(
        color: Colors.white.withValues(alpha: 0.85),
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: mistGray, width: 0.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: jadeGreen,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: mistGray),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: mistGray),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: jadeGreen, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: mistGray,
        thickness: 0.5,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: paperWhite,
        indicatorColor: jadeGreen.withValues(alpha: 0.15),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: inkBlack.withValues(alpha: 0.8)),
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: jadeGreen,
      brightness: Brightness.dark,
      surface: const Color(0xFF121212),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF121212),
      fontFamily: 'serif',
      cardTheme: CardThemeData(
        color: const Color(0xFF1E1E1E),
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1E1E1E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF121212),
        indicatorColor: jadeGreen.withValues(alpha: 0.3),
      ),
    );
  }
}
