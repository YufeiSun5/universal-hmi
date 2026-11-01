import 'package:flutter/material.dart';

/// Opt-in chrome for ordinary desktop forms. GIS and login keep their themes.
abstract final class DesktopDialogStyle {
  static const background = Color(0xfffcfcfd);
  static const header = Color(0xfff1f3f5);
  static const line = Color(0xffc4cdd4);
  static const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(4)),
    side: BorderSide(color: line),
  );
  static const insetPadding = EdgeInsets.all(16);
  static const titlePadding = EdgeInsets.fromLTRB(16, 12, 16, 12);
  static const contentPadding = EdgeInsets.all(16);
  static const actionsPadding = EdgeInsets.fromLTRB(16, 12, 16, 12);
}

class DesktopDialogTitle extends StatelessWidget {
  const DesktopDialogTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    padding: DesktopDialogStyle.titlePadding,
    decoration: const BoxDecoration(
      color: DesktopDialogStyle.header,
      border: Border(bottom: BorderSide(color: DesktopDialogStyle.line)),
    ),
    child: Tooltip(
      message: title,
      child: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
