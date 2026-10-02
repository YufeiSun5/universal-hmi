import 'package:flutter/material.dart';

/// Light desktop chrome matched to the user's reference workspace.
abstract final class WorkbenchColors {
  static const ink = Color(0xff29384f);
  static const muted = Color(0xff72809b);
  static const accent = Color(0xff3565f5);
  static const paper = Color(0xffffffff);
  static const chrome = Color(0xfff4f6f9);
  static const line = Color(0xffd8e0ec);
  static const selection = Color(0xffe8eeff);
  static const amber = Color(0xff986c22);
}

const numericStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

ThemeData workspaceTheme([bool dark = false]) {
  const scheme = ColorScheme.light(
    primary: WorkbenchColors.accent,
    onPrimary: Colors.white,
    primaryContainer: WorkbenchColors.selection,
    onPrimaryContainer: WorkbenchColors.ink,
    secondary: Color(0xff64789c),
    surface: WorkbenchColors.paper,
    onSurface: WorkbenchColors.ink,
    onSurfaceVariant: WorkbenchColors.muted,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xfff5f7fa),
    surfaceContainer: WorkbenchColors.chrome,
    surfaceContainerHigh: Color(0xffedf1f7),
    outline: Color(0xffaab7cc),
    outlineVariant: WorkbenchColors.line,
    error: Color(0xffb24637),
    errorContainer: Color(0xfff8e6df),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'HmiCJK',
    fontFamilyFallback: const ['Roboto'],
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 13, height: 1.4),
      bodyMedium: TextStyle(fontSize: 12, height: 1.35),
      bodySmall: TextStyle(fontSize: 11, height: 1.35),
      labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
    dividerTheme: const DividerThemeData(
      color: WorkbenchColors.line,
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: WorkbenchColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: WorkbenchColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: WorkbenchColors.accent, width: 1.3),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: const BorderSide(color: WorkbenchColors.line),
        foregroundColor: WorkbenchColors.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        maximumSize: const Size(34, 34),
        padding: const EdgeInsets.all(6),
        foregroundColor: WorkbenchColors.muted,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      side: const BorderSide(color: Color(0xffaab7cc)),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      thumbColor: WidgetStatePropertyAll(scheme.outline.withValues(alpha: .65)),
      radius: const Radius.circular(4),
    ),
  );
}

Color qualityColor(String q, ColorScheme c) => switch (q) {
  'good' => const Color(0xff009c85),
  'imported' => const Color(0xff527697),
  'bad' => c.error,
  _ => WorkbenchColors.amber,
};
String qualityLabel(String q) => switch (q) {
  'good' => '正常',
  'bad' => '坏质量',
  'stale' => '陈旧',
  'imported' => '导入',
  _ => '无数据',
};
