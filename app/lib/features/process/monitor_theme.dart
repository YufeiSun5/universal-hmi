import 'package:flutter/material.dart';

abstract final class MonitorColors {
  static const background = Color(0xff142f43);
  static const panel = Color(0xff102638);
  static const header = Color(0xff071926);
  static const line = Color(0xff28495e);
  static const cyan = Color(0xff42c8ff);
  static const text = Color(0xffe0eef6);
  static const muted = Color(0xff91afc3);
  static const warning = Color(0xffffcf73);

  static ThemeData theme(ThemeData base) => base.copyWith(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: cyan,
      surface: panel,
      onSurface: text,
      outline: line,
      error: warning,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xff0b2030),
      hintStyle: TextStyle(color: muted, fontSize: 12),
      border: OutlineInputBorder(borderSide: BorderSide(color: line)),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line)),
      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cyan)),
      isDense: true,
    ),
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    iconTheme: const IconThemeData(color: cyan, size: 19),
    dividerColor: line,
    tooltipTheme: const TooltipThemeData(
      textStyle: TextStyle(fontSize: 12, color: text),
      decoration: BoxDecoration(color: header),
    ),
  );
}
