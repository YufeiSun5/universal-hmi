import 'package:flutter/material.dart';
import '../shared/form_control_theme.dart';

class SecurityTheme extends StatelessWidget {
  const SecurityTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => FormControlTheme(
    child: Builder(
      builder: (context) {
        final base = Theme.of(context);
        final shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        );
        return Theme(
          data: base.copyWith(
            filledButtonTheme: FilledButtonThemeData(
              style: base.filledButtonTheme.style?.copyWith(
                backgroundColor: const WidgetStateProperty.fromMap({
                  WidgetState.disabled: Color(0xffe2e7ed),
                  WidgetState.any: Color(0xff285e98),
                }),
                foregroundColor: const WidgetStateProperty.fromMap({
                  WidgetState.disabled: Color(0xff8794a4),
                  WidgetState.any: Colors.white,
                }),
                shape: WidgetStatePropertyAll(shape),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: base.outlinedButtonTheme.style?.copyWith(
                side: const WidgetStateProperty.fromMap({
                  WidgetState.disabled: BorderSide(color: Color(0xffe2e7ed)),
                  WidgetState.any: BorderSide(color: Color(0xffaab8c8)),
                }),
                shape: WidgetStatePropertyAll(shape),
              ),
            ),
            listTileTheme: base.listTileTheme.copyWith(
              dense: false,
              minVerticalPadding: 12,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
            ),
          ),
          child: child,
        );
      },
    ),
  );
}

/// Scrollable management content with deliberate separation between fields.
class SecurityList extends StatelessWidget {
  const SecurityList({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(24),
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => ListView(
    padding: padding,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i != 0) const SizedBox(height: 16),
        children[i],
      ],
    ],
  );
}

class SecurityDetails extends StatelessWidget {
  const SecurityDetails({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffdce3eb)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i != 0) const SizedBox(height: 10),
          children[i],
        ],
      ],
    ),
  );
}

/// Actions move below the record at narrow widths instead of squeezing its data.
class SecurityRecord extends StatelessWidget {
  const SecurityRecord({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: SecurityDetails(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                child: title,
              ),
            ),
          ],
        ),
        if (subtitle != null)
          DefaultTextStyle.merge(
            style: const TextStyle(height: 1.7, color: Color(0xff596b80)),
            child: subtitle!,
          ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class SecurityDangerButton extends StatelessWidget {
  const SecurityDangerButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon = Icons.block_outlined,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final IconData icon;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: child,
    style: OutlinedButton.styleFrom(
      foregroundColor: const Color(0xffa93532),
      side: BorderSide(
        color: onPressed == null
            ? const Color(0xffe2e7ed)
            : const Color(0xffd7aaa7),
      ),
      backgroundColor: const Color(0xfffff8f7),
    ),
  );
}

class SecuritySection extends StatelessWidget {
  const SecuritySection({
    super.key,
    required this.title,
    this.description,
    required this.child,
  });
  final String title;
  final String? description;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe0e5ec)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 20),
        child,
      ],
    ),
  );
}
