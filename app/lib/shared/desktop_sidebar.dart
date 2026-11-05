import 'package:flutter/material.dart';

/// Compact desktop navigation chrome; callers retain their own data and actions.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.search,
    this.footer,
  });
  static const width = 248.0;
  static const panel = Color(0xffe2e6e9);
  static const line = Color(0xffc4cdd4);
  static const ink = Color(0xff293d4b);
  static const muted = Color(0xff647581);
  static const selection = Color(0xffcbd4dc);
  final String title;
  final Widget child;
  final List<Widget> actions;
  final Widget? search, footer;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: panel,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
        if (search != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: SizedBox(height: 32, child: search),
          ),
        Expanded(child: child),
        if (footer != null) footer!,
      ],
    ),
  );
}

class DesktopSidebarSearch extends StatelessWidget {
  const DesktopSidebarSearch({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.fieldKey,
  });
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    onChanged: onChanged,
    style: const TextStyle(fontSize: 12, color: DesktopSidebar.ink),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: DesktopSidebar.muted),
      isDense: true,
      filled: true,
      fillColor: const Color(0xfff5f6f7),
      prefixIcon: const Icon(
        Icons.search,
        size: 15,
        color: DesktopSidebar.muted,
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 30),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: DesktopSidebar.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: DesktopSidebar.muted),
      ),
    ),
  );
}

class DesktopSidebarRow extends StatelessWidget {
  const DesktopSidebarRow({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.indent = 0,
    this.trailing,
    this.tooltip,
  });
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final double indent;
  final Widget? trailing;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(6 + indent, 0, 6, 1),
    child: Tooltip(
      message: tooltip ?? title,
      child: Material(
        color: selected ? DesktopSidebar.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: DesktopSidebar.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: DesktopSidebar.ink,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
