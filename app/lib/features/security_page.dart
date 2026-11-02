import 'package:flutter/material.dart';
import 'security_layout.dart';

/// Security administration uses ordinary pages inside the development workspace.
/// The existing standalone account/read-only entries retain their own presentation.
class SecurityPageScope extends InheritedWidget {
  const SecurityPageScope({
    super.key,
    required this.root,
    required super.child,
  });
  final bool root;
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SecurityPageScope>() != null;
  static bool isRoot(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SecurityPageScope>()?.root ==
      true;
  @override
  bool updateShouldNotify(SecurityPageScope oldWidget) =>
      root != oldWidget.root;
}

Future<T?> openSecurityPage<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (!SecurityPageScope.contains(context)) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
  }
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (context) =>
          SecurityPageScope(root: false, child: Builder(builder: builder)),
    ),
  );
}

class SecuritySurface extends Dialog {
  const SecuritySurface({
    super.key,
    super.child,
    super.shape,
    super.clipBehavior,
    super.backgroundColor,
    super.insetPadding,
  });
  @override
  Widget build(BuildContext context) {
    if (!SecurityPageScope.contains(context)) {
      return SecurityTheme(
        child: Dialog(
          shape: shape,
          clipBehavior: clipBehavior,
          backgroundColor: backgroundColor,
          insetPadding: insetPadding,
          child: child,
        ),
      );
    }
    return SecurityTheme(
      child: Material(
        color: const Color(0xfff8fafc),
        child: SizedBox.expand(child: child),
      ),
    );
  }
}

class SecurityForm extends AlertDialog {
  const SecurityForm({
    super.key,
    super.title,
    super.content,
    super.actions,
    super.shape,
    super.clipBehavior,
    super.backgroundColor,
    super.insetPadding,
    super.titlePadding,
    super.contentPadding,
    super.actionsPadding,
  });
  @override
  Widget build(BuildContext context) {
    if (!SecurityPageScope.contains(context)) {
      return SecurityTheme(
        child: AlertDialog(
          title: title,
          content: content,
          actions: actions,
          shape: shape,
          clipBehavior: clipBehavior,
          backgroundColor: backgroundColor,
          insetPadding: insetPadding,
          titlePadding: titlePadding,
          contentPadding: contentPadding,
          actionsPadding: actionsPadding,
        ),
      );
    }
    return SecurityTheme(
      child: Material(
        color: const Color(0xfff8fafc),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Container(
                decoration: const BoxDecoration(
                  color: Color(0xfff1f3f5),
                  border: Border(bottom: BorderSide(color: Color(0xffdce3eb))),
                ),
                padding: titlePadding ?? const EdgeInsets.all(16),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                  child: title!,
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: content ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            if (actions?.isNotEmpty == true)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Color(0xffdce3eb))),
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: actions!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
