import 'package:flutter/material.dart';

/// Query controls use desktop toolbar density, separate from account forms.
class QueryControlTheme extends StatelessWidget {
  const QueryControlTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final touch = MediaQuery.sizeOf(context).width < 600;
    final fontSize = touch ? 14.0 : 13.0;
    final scale = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
    final height = (touch ? 44.0 : 34.0) * (scale < 1 ? 1 : scale);
    final button = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(touch ? 72 : 64, height)),
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(height)),
      maximumSize: const WidgetStatePropertyAll(Size.infinite),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStatePropertyAll(
        base.textTheme.labelLarge?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconSize: const WidgetStatePropertyAll(17),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
    return Theme(
      data: base.copyWith(
        visualDensity: VisualDensity.standard,
        textTheme: base.textTheme.copyWith(
          bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: fontSize),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: fontSize),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          isDense: true,
          constraints: BoxConstraints(minHeight: height, maxHeight: height),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 6,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          labelStyle: base.textTheme.bodySmall?.copyWith(fontSize: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
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
            minimumSize: Size(height, height),
            maximumSize: Size(height, height),
            padding: const EdgeInsets.all(6),
            iconSize: 18,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
      child: child,
    );
  }
}
