import 'package:flutter/material.dart';

ThemeData workspaceTheme(bool dark) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff779cfa),
    brightness: dark ? Brightness.dark : Brightness.light,
    surface: dark ? const Color(0xff191b20) : const Color(0xfffafbfc),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'sans-serif',
    visualDensity: VisualDensity.compact,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 13),
      bodySmall: TextStyle(fontSize: 12),
      labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .65),
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

Color qualityColor(String q, ColorScheme c) => switch (q) {
  'good' => const Color(0xff47be97),
  'imported' => c.primary,
  'bad' => c.error,
  _ => const Color(0xffd5aa61),
};
String qualityLabel(String q) => switch (q) {
  'good' => '正常',
  'bad' => '坏质量',
  'stale' => '陈旧',
  'imported' => '导入',
  _ => '无数据',
};
