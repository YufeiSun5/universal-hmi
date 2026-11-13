import 'package:flutter/material.dart';

/// Form density is independent of the compact engineering tables.
class FormControlTheme extends StatelessWidget {
  const FormControlTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final button = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(80, 44)),
      maximumSize: const WidgetStatePropertyAll(Size.infinite),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.padded,
      textStyle: WidgetStatePropertyAll(
        base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    return Theme(
      data: base.copyWith(
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        textTheme: base.textTheme.copyWith(
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontSize: 14,
            height: 1.5,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            height: 1.5,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.5,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          isDense: false,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 16,
          ),
          constraints: const BoxConstraints(minHeight: 52),
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: base.filledButtonTheme.style?.merge(button) ?? button,
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: base.outlinedButtonTheme.style?.merge(button) ?? button,
        ),
        textButtonTheme: TextButtonThemeData(
          style: base.textButtonTheme.style?.merge(button) ?? button,
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            maximumSize: const Size(48, 48),
            padding: const EdgeInsets.all(10),
          ),
        ),
      ),
      child: child,
    );
  }
}
