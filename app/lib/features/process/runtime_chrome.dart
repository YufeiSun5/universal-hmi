import 'package:flutter/material.dart';
import '../../shared/button_styles.dart';
import '../../shared/desktop_sidebar.dart';

abstract final class RuntimeStyle {
  static const paper = Color(0xffe9ecef);
  static const ink = Color(0xff2d3e50);
  static const muted = Color(0xff74818e);
  static const accent = Color(0xff536b83);
  static const line = Color(0xffc6ced6);
  static const selection = Color(0xffdfe6ed);
  static const scheme = ColorScheme.light(
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: selection,
    onPrimaryContainer: ink,
    secondary: Color(0xff6b7c8e),
    onSecondary: Colors.white,
    secondaryContainer: selection,
    onSecondaryContainer: ink,
    surface: Color(0xfffcfcfd),
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xfff3f5f7),
    surfaceContainer: paper,
    surfaceContainerHigh: Color(0xffe0e5ea),
    surfaceContainerHighest: Color(0xffd7dee5),
    surfaceTint: Colors.transparent,
    outline: Color(0xffaebbc7),
    outlineVariant: line,
    error: Color(0xffb04436),
    errorContainer: Color(0xfff8e6df),
    onErrorContainer: Color(0xff7a2c25),
  );
  static OutlineInputBorder fieldBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: color, width: width),
      );
  static ThemeData theme(ThemeData base) => base.copyWith(
    brightness: Brightness.light,
    scaffoldBackgroundColor: paper,
    colorScheme: scheme,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    iconTheme: const IconThemeData(color: muted, size: 20),
    dividerColor: line,
    filledButtonTheme: FilledButtonThemeData(
      style: AppButtonStyles.primary(scheme, height: 34),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: AppButtonStyles.secondary(scheme, height: 34),
    ),
    textButtonTheme: TextButtonThemeData(style: AppButtonStyles.quiet(scheme)),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: fieldBorder(line),
      enabledBorder: fieldBorder(line),
      disabledBorder: fieldBorder(line.withValues(alpha: .6)),
      focusedBorder: fieldBorder(accent, 1.2),
      errorBorder: fieldBorder(scheme.error),
      focusedErrorBorder: fieldBorder(scheme.error, 1.2),
      hintStyle: const TextStyle(color: muted),
      labelStyle: const TextStyle(color: muted),
      floatingLabelStyle: const TextStyle(color: accent),
      prefixIconColor: muted,
    ),
  );
}

/// Light content chrome. MonitorHeader and GIS keep their independent styles.
abstract final class ProcessStyle {
  static const panel = Color(0xffe2e6e9);
  static const heading = Color(0xffe8ecef);
  static const line = Color(0xffc4cdd4);
  static const ink = Color(0xff293d4b);
  static const muted = Color(0xff647581);
  static const accent = Color(0xff465f71);
  static ThemeData theme(ThemeData base) => RuntimeStyle.theme(base).copyWith(
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: Color(0xffcbd4dc),
      onPrimaryContainer: ink,
      surface: panel,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: line,
      outlineVariant: line,
    ),
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    iconTheme: const IconThemeData(color: muted, size: 20),
    dividerColor: line,
  );
}

/// Scrollbar makes horizontal filter actions discoverable in small windows.
class RuntimeToolbar extends StatefulWidget {
  const RuntimeToolbar({super.key, required this.children});
  final List<Widget> children;
  @override
  State<RuntimeToolbar> createState() => _RuntimeToolbarState();
}

class _RuntimeToolbarState extends State<RuntimeToolbar> {
  final controller = ScrollController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 54,
    child: Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            for (final child in widget.children)
              Padding(padding: const EdgeInsets.only(right: 8), child: child),
          ],
        ),
      ),
    ),
  );
}

class RuntimeHeading extends StatelessWidget {
  const RuntimeHeading({
    super.key,
    required this.title,
    required this.subtitle,
    required this.online,
    this.onMenu,
    this.process = false,
  });
  final String title, subtitle;
  final bool online, process;
  final VoidCallback? onMenu;
  @override
  Widget build(BuildContext context) => Container(
    color: process ? ProcessStyle.heading : null,
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    child: Row(
      children: [
        if (onMenu != null) ...[
          IconButton(
            key: const Key('runtime-toggle-menu'),
            tooltip: '显示或收起目录',
            onPressed: onMenu,
            icon: Icon(
              Icons.menu_open,
              color: process ? ProcessStyle.muted : RuntimeStyle.muted,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: process ? 19 : 21,
                  fontWeight: FontWeight.w600,
                  color: process ? ProcessStyle.ink : RuntimeStyle.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: process ? ProcessStyle.muted : RuntimeStyle.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Icon(
          online ? Icons.check_circle_outline : Icons.cloud_off,
          size: 16,
          color: online
              ? (process ? ProcessStyle.accent : RuntimeStyle.accent)
              : const Color(0xffd98370),
        ),
        const SizedBox(width: 6),
        Text(
          online ? '已连接' : '离线',
          style: TextStyle(
            fontSize: 12,
            color: online
                ? (process ? ProcessStyle.accent : RuntimeStyle.accent)
                : const Color(0xffd98370),
          ),
        ),
      ],
    ),
  );
}

class RuntimeStationList extends StatefulWidget {
  const RuntimeStationList({
    super.key,
    required this.stations,
    required this.selected,
    required this.onSelect,
  });
  final List<String> stations;
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  State<RuntimeStationList> createState() => _RuntimeStationListState();
}

class _RuntimeStationListState extends State<RuntimeStationList> {
  String query = '';
  @override
  Widget build(BuildContext context) => DesktopSidebar(
    title: '站点范围',
    search: DesktopSidebarSearch(
      hint: '搜索站点',
      onChanged: (s) => setState(() => query = s.trim().toLowerCase()),
    ),
    child: ListView(
      children: [
        for (final s in [
          '',
          ...widget.stations,
        ].where((s) => s.isEmpty || s.toLowerCase().contains(query)))
          DesktopSidebarRow(
            key: Key('runtime-scope-$s'),
            title: s.isEmpty ? '全部站点' : s,
            icon: s.isEmpty ? Icons.grid_view : Icons.apartment_outlined,
            selected: widget.selected == s,
            onTap: () => widget.onSelect(s),
          ),
      ],
    ),
  );
}
