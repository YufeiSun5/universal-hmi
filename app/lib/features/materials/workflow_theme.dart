import 'package:flutter/material.dart';

/// Shared Material controls for the materials workflow, scoped to its dialogs.
class MaterialWorkflowTheme extends StatelessWidget {
  const MaterialWorkflowTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final label = base.textTheme.labelLarge?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.copyWith(
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontSize: 15,
            height: 1.4,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontSize: 15,
            height: 1.4,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          labelStyle: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
          helperStyle: base.textTheme.bodySmall?.copyWith(fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 14,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            visualDensity: VisualDensity.standard,
            textStyle: label,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ).merge(base.filledButtonTheme.style),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            visualDensity: VisualDensity.standard,
            textStyle: label,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ).merge(base.outlinedButtonTheme.style),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 40),
            textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 14),
          ).merge(base.textButtonTheme.style),
        ),
      ),
      child: child,
    );
  }
}

class MaterialWorkflowDialog extends StatelessWidget {
  const MaterialWorkflowDialog({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => MaterialWorkflowTheme(
    child: Dialog(insetPadding: const EdgeInsets.all(12), child: child),
  );
}

class MaterialWorkflowAlert extends StatelessWidget {
  const MaterialWorkflowAlert({
    super.key,
    this.title,
    this.content,
    this.actions,
  });
  final Widget? title, content;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => MaterialWorkflowTheme(
    child: AlertDialog(title: title, content: content, actions: actions),
  );
}

Widget materialError(String message, {VoidCallback? retry}) => Padding(
  padding: const EdgeInsets.all(12),
  child: Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(message, style: const TextStyle(color: Color(0xffb3261e))),
      if (retry != null)
        OutlinedButton(onPressed: retry, child: const Text('重试')),
    ],
  ),
);
