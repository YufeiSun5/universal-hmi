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
            scaffoldBackgroundColor: const Color(0xfff2f5f8),
            dividerTheme: const DividerThemeData(
              color: Color(0xffdce4ec),
              thickness: 1,
              space: 1,
            ),
            appBarTheme: base.appBarTheme.copyWith(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xff294258),
              elevation: 0,
              scrolledUnderElevation: 0,
              titleTextStyle: base.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: const Color(0xff294258),
              ),
            ),
            inputDecorationTheme: base.inputDecorationTheme.copyWith(
              fillColor: Colors.white,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            tabBarTheme: base.tabBarTheme.copyWith(
              labelColor: const Color(0xff365e83),
              unselectedLabelColor: const Color(0xff778797),
              indicatorColor: const Color(0xff50779b),
              dividerColor: const Color(0xffdce4ec),
            ),
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
              minVerticalPadding: 8,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
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
    this.padding = const EdgeInsets.all(18),
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => ListView(
    padding: padding,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i != 0) const SizedBox(height: 12),
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
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffdde5ed)),
      borderRadius: BorderRadius.circular(6),
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
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffdde5ed)),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 820;
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff294258),
                      ),
                      child: title,
                    ),
                  ),
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                DefaultTextStyle.merge(
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.55,
                    color: Color(0xff6b7e90),
                  ),
                  child: subtitle!,
                ),
              ],
              if (!wide && trailing != null) ...[
                const SizedBox(height: 12),
                trailing!,
              ],
            ],
          );
          return wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: content),
                    if (trailing != null) ...[
                      const SizedBox(width: 20),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: trailing!,
                      ),
                    ],
                  ],
                )
              : content;
        },
      ),
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
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe0e5ec)),
      borderRadius: BorderRadius.circular(6),
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
