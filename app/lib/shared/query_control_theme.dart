import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Query controls use desktop toolbar density, separate from account forms.
class QueryControlTheme extends StatelessWidget {
  const QueryControlTheme({super.key, required this.child, this.minHeight = 0});
  final Widget child;
  final double minHeight;

  static bool isTouch(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ||
      (kIsWeb && Uri.base.queryParameters['client'] == 'android');

  static double controlHeight(BuildContext context) {
    final touch = isTouch(context);
    final font = touch ? 14.0 : 13.0;
    final scale = MediaQuery.textScalerOf(context).scale(font) / font;
    return (touch ? 44.0 : 34.0) * (scale < 1 ? 1 : scale);
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final touch = isTouch(context);
    final fontSize = touch ? 14.0 : 13.0;
    final height = controlHeight(context).clamp(minHeight, double.infinity);
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
          // A tight control box should also determine the painted outline.
          // Dense decorators can leave a shorter dropdown outline inside it.
          isDense: false,
          filled: true,
          fillColor: base.colorScheme.surface,
          constraints: BoxConstraints(minHeight: height, maxHeight: height),
          prefixIconConstraints: BoxConstraints.tightFor(
            width: height,
            height: height,
          ),
          suffixIconConstraints: BoxConstraints.tightFor(
            width: height,
            height: height,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 6,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          labelStyle: base.textTheme.bodySmall?.copyWith(fontSize: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: base.colorScheme.outlineVariant),
          ),
        ),
        chipTheme: base.chipTheme.copyWith(
          labelStyle: base.textTheme.labelLarge?.copyWith(fontSize: fontSize),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          side: BorderSide(color: base.colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(style: button),
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
