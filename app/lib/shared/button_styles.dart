import 'package:flutter/material.dart';

/// Shared compact controls with distinct action hierarchy and visible focus.
abstract final class AppButtonStyles {
  static ButtonStyle primary(ColorScheme scheme, {double height = 32}) =>
      FilledButton.styleFrom(
        minimumSize: Size(0, height),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(
          fontFamily: 'HmiCJK',
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
      ).copyWith(
        elevation: const WidgetStateProperty.fromMap({
          WidgetState.disabled: 0.0,
          WidgetState.pressed: 0.0,
          WidgetState.any: 0.0,
        }),
        side: WidgetStateProperty.fromMap({
          WidgetState.focused: BorderSide(color: scheme.onSurface, width: 1.2),
          WidgetState.any: const BorderSide(
            color: Colors.transparent,
            width: 1.2,
          ),
        }),
      );

  static ButtonStyle secondary(ColorScheme scheme, {double height = 32}) =>
      OutlinedButton.styleFrom(
        minimumSize: Size(0, height),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        foregroundColor: scheme.onSurface,
        backgroundColor: scheme.surface,
        textStyle: const TextStyle(
          fontFamily: 'HmiCJK',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        surfaceTintColor: Colors.transparent,
      ).copyWith(
        side: WidgetStateProperty.fromMap({
          WidgetState.disabled: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .5),
          ),
          WidgetState.focused: BorderSide(color: scheme.primary),
          WidgetState.hovered: BorderSide(color: scheme.primary),
          WidgetState.any: BorderSide(color: scheme.outlineVariant),
        }),
        backgroundColor: WidgetStateProperty.fromMap({
          WidgetState.disabled: scheme.surfaceContainerLow,
          WidgetState.hovered: scheme.primaryContainer.withValues(alpha: .45),
          WidgetState.any: scheme.surface,
        }),
      );

  static ButtonStyle quiet(ColorScheme scheme) =>
      TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(
          fontFamily: 'HmiCJK',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ).copyWith(
        side: WidgetStateProperty.fromMap({
          WidgetState.focused: BorderSide(color: scheme.primary),
          WidgetState.any: const BorderSide(color: Colors.transparent),
        }),
      );
}
