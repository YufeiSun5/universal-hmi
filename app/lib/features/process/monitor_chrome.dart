import 'dart:async';
import 'package:flutter/material.dart';
import 'monitor_theme.dart';
import 'runtime_chrome.dart';

/// Decorative navigation only; destinations and station scope belong to host.
class MonitorHeader extends StatelessWidget {
  const MonitorHeader({
    super.key,
    required this.compact,
    required this.onNavigate,
    this.showGis = false,
    this.activePage = 9,
    this.username,
    this.onLogout,
    this.onSecurity,
    this.onAccount,
  });
  final bool compact;
  final bool showGis;
  final int activePage;
  final ValueChanged<int> onNavigate;
  final String? username;
  final VoidCallback? onLogout;
  final VoidCallback? onSecurity;
  final VoidCallback? onAccount;

  Widget get brand => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '智慧供热集中监控系统',
          maxLines: 1,
          style: TextStyle(
            fontSize: compact ? 18 : 20,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: .7,
            color: showGis ? const Color(0xffdcf8ff) : ProcessStyle.ink,
            shadows: showGis
                ? const [Shadow(color: Color(0x9942c8ff), blurRadius: 16)]
                : null,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Container(
              width: 22,
              height: 2,
              decoration: BoxDecoration(
                color: showGis ? null : ProcessStyle.accent,
                gradient: showGis
                    ? const LinearGradient(
                        colors: [MonitorColors.cyan, Color(0x0042c8ff)],
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              showGis ? '集中监控 · 站区总览' : '集中监控 · 工艺可视化',
              style: TextStyle(
                fontSize: 10,
                height: 1.2,
                letterSpacing: 2,
                color: showGis ? MonitorColors.muted : ProcessStyle.muted,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget get actions => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!compact) ...[
        _MonitorClock(showGis: showGis),
        const SizedBox(width: 20),
        Container(
          width: 1,
          height: 32,
          color: showGis ? const Color(0x3342c8ff) : ProcessStyle.line,
        ),
        const SizedBox(width: 12),
      ],
      if (!compact && username != null)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 80),
            child: Text(
              username!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: showGis ? MonitorColors.muted : ProcessStyle.muted,
                fontSize: 12,
              ),
            ),
          ),
        ),
      if (onLogout != null)
        IconButton(
          key: const Key('logout'),
          color: showGis ? null : ProcessStyle.muted,
          tooltip: '退出登录',
          onPressed: onLogout,
          icon: const Icon(Icons.logout, size: 19),
        ),
      if (onSecurity != null)
        IconButton(
          tooltip: '用户与权限',
          color: showGis ? null : ProcessStyle.muted,
          onPressed: onSecurity,
          icon: const Icon(Icons.manage_accounts_outlined, size: 20),
        ),
      if (onAccount != null)
        IconButton(
          tooltip: '账号安全',
          color: showGis ? null : ProcessStyle.muted,
          onPressed: onAccount,
          icon: const Icon(Icons.security, size: 20),
        ),
      const SizedBox(width: 16),
    ],
  );

  Widget get navigation => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _MonitorNavButton(
          showGis: showGis,
          asset: 'gis',
          label: 'GIS',
          tooltip: '站区地图',
          selected: showGis,
          onTap: () => onNavigate(11),
        ),
        _MonitorNavButton(
          showGis: showGis,
          asset: 'process',
          label: '工艺画面',
          selected: activePage == 9,
          onTap: () => onNavigate(9),
        ),
        _MonitorNavButton(
          showGis: showGis,
          asset: 'equipment',
          label: '设备台账',
          selected: activePage == 13,
          onTap: () => onNavigate(13),
        ),
        _MonitorNavButton(
          showGis: showGis,
          asset: 'history',
          label: '历史',
          selected: activePage == 12,
          onTap: () => onNavigate(12),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Container(
      key: const Key('monitor-header-background'),
      height: compact ? 112 : 76,
      decoration: showGis
          ? null
          : const BoxDecoration(
              color: Color(0xffdce3e8),
              border: Border(bottom: BorderSide(color: ProcessStyle.line)),
            ),
      child: CustomPaint(
        child: compact
            ? Column(
                children: [
                  SizedBox(
                    height: 42,
                    child: Row(
                      children: [
                        Expanded(child: brand),
                        actions,
                      ],
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: navigation,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  SizedBox(width: 306, child: brand),
                  Expanded(child: Center(child: navigation)),
                  actions,
                ],
              ),
      ),
    ),
  );
}

/// Navigation artwork shares one shell, color treatment and interaction states.
class _MonitorNavButton extends StatefulWidget {
  const _MonitorNavButton({
    required this.showGis,
    required this.asset,
    required this.label,
    this.selected = false,
    this.onTap,
    this.tooltip,
  });
  final String asset, label;
  final bool showGis;
  final bool selected;
  final VoidCallback? onTap;
  final String? tooltip;
  @override
  State<_MonitorNavButton> createState() => _MonitorNavButtonState();
}

class _MonitorNavButtonState extends State<_MonitorNavButton> {
  bool hovered = false, focused = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final plain = !widget.showGis;
    final highlighted = active || hovered || focused;
    final enabled = widget.onTap != null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      selected: active,
      child: Tooltip(
        message: widget.tooltip ?? widget.label,
        child: SizedBox(
          width: 96,
          height: 70,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              onHover: (value) => setState(() => hovered = value),
              onFocusChange: (value) => setState(() => focused = value),
              borderRadius: BorderRadius.circular(10),
              hoverColor: Colors.transparent,
              focusColor: const Color(0x1842c8ff),
              child: AnimatedContainer(
                duration: duration,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: plain && !active && (hovered || focused)
                      ? const Color(0xffd2dbe2)
                      : null,
                  gradient: plain
                      ? null
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: highlighted
                              ? [
                                  const Color(0x0042c8ff),
                                  Color(active ? 0x3035bfff : 0x1735bfff),
                                ]
                              : const [Colors.transparent, Colors.transparent],
                        ),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 2),
                    AnimatedContainer(
                      duration: duration,
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: plain
                            ? []
                            : [
                                BoxShadow(
                                  color: const Color(0xff20baff).withValues(
                                    alpha: active
                                        ? .33
                                        : highlighted
                                        ? .12
                                        : 0,
                                  ),
                                  blurRadius: active ? 26 : 14,
                                  spreadRadius: -8,
                                ),
                              ],
                      ),
                      child: AnimatedOpacity(
                        duration: duration,
                        opacity: !enabled
                            ? .38
                            : highlighted
                            ? 1
                            : plain
                            ? .85
                            : .60,
                        child: Stack(
                          children: [
                            ColorFiltered(
                              // Preserve every luminance detail and the original
                              // alpha. Quiet blue-gray engraving on a pale base;
                              // srcIn would flatten these full-disc PNGs to circles.
                              colorFilter: plain && !active
                                  ? const ColorFilter.matrix([
                                      -.1212,
                                      -.4077,
                                      -.0411,
                                      0,
                                      220,
                                      -.1127,
                                      -.3791,
                                      -.0382,
                                      0,
                                      228,
                                      -.1000,
                                      -.3361,
                                      -.0339,
                                      0,
                                      234,
                                      0,
                                      0,
                                      0,
                                      1,
                                      0,
                                    ])
                                  : const ColorFilter.mode(
                                      Colors.white,
                                      BlendMode.modulate,
                                    ),
                              child: Image.asset(
                                'assets/monitor/${widget.asset}.png',
                                width: 48,
                                height: 48,
                                cacheWidth: 144,
                                excludeFromSemantics: true,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            if (active && !plain)
                              Center(
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        Color(0x4234caff),
                                        Color(0x0034caff),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: plain
                            ? (active ? ProcessStyle.accent : ProcessStyle.ink)
                            : active
                            ? const Color(0xffe7fbff)
                            : enabled
                            ? const Color(0xffa8c6db)
                            : MonitorColors.muted,
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                        letterSpacing: 1,
                        shadows: active && !plain
                            ? const [
                                Shadow(
                                  color: MonitorColors.cyan,
                                  blurRadius: 10,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const Spacer(),
                    AnimatedContainer(
                      duration: duration,
                      width: active ? 70 : 0,
                      height: 2,
                      decoration: BoxDecoration(
                        color: plain ? ProcessStyle.accent : null,
                        gradient: plain
                            ? null
                            : const LinearGradient(
                                colors: [
                                  Color(0x003bd5ff),
                                  Color(0xff9ceeff),
                                  Color(0x003bd5ff),
                                ],
                              ),
                        boxShadow: plain
                            ? []
                            : const [
                                BoxShadow(
                                  color: Color(0xff20aaff),
                                  blurRadius: 8,
                                ),
                              ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MonitorStationList extends StatelessWidget {
  const MonitorStationList({
    super.key,
    required this.stations,
    required this.selected,
    required this.query,
    required this.search,
    required this.onQuery,
    required this.onSelected,
  });
  final List<String> stations;
  final String selected, query;
  final TextEditingController search;
  final ValueChanged<String> onQuery, onSelected;

  @override
  Widget build(BuildContext context) {
    final filtered = stations
        .where((s) => s.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0a2338), Color(0xff071a2c)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 17, 10, 13),
            child: Row(
              children: [
                Image.asset(
                  'assets/monitor/station.png',
                  width: 42,
                  height: 42,
                  cacheWidth: 128,
                  excludeFromSemantics: true,
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    '换热站',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: Color(0xffdcf5ff),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x1536bfff),
                    border: Border.all(color: const Color(0x3036bfff)),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '${stations.length} 站',
                    key: const Key('monitor-station-count'),
                    style: const TextStyle(
                      color: MonitorColors.muted,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 16),
            child: SizedBox(
              height: 37,
              child: TextField(
                key: const Key('monitor-station-search'),
                controller: search,
                onChanged: onQuery,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索站点',
                  hintStyle: const TextStyle(color: Color(0xff6d91ac)),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 17,
                    color: Color(0xff6d91ac),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            search.clear();
                            onQuery('');
                          },
                          icon: const Icon(Icons.close, size: 14),
                        ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xff061728),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: Color(0xff24465f)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: MonitorColors.cyan),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      stations.isEmpty ? '尚未配置站点' : '没有匹配的站点',
                      style: const TextStyle(
                        color: MonitorColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('monitor-station-list'),
                    itemCount: filtered.length,
                    itemExtent: 62,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemBuilder: (_, i) {
                      final station = filtered[i], active = station == selected;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Semantics(
                          selected: active,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: ValueKey('monitor-station-$station'),
                              borderRadius: BorderRadius.circular(7),
                              onTap: () => onSelected(station),
                              hoverColor: const Color(0x1235bfff),
                              child: Ink(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(7),
                                  gradient: active
                                      ? const LinearGradient(
                                          colors: [
                                            Color(0xff134b6d),
                                            Color(0xff0c2b45),
                                          ],
                                        )
                                      : null,
                                  border: Border.all(
                                    color: active
                                        ? const Color(0xff277aa0)
                                        : const Color(0x162d6688),
                                  ),
                                  boxShadow: active
                                      ? const [
                                          BoxShadow(
                                            color: Color(0x1432baff),
                                            blurRadius: 12,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 3,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(2),
                                        color: active
                                            ? const Color(0xff76e5ff)
                                            : Colors.transparent,
                                        boxShadow: active
                                            ? const [
                                                BoxShadow(
                                                  color: MonitorColors.cyan,
                                                  blurRadius: 8,
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    Opacity(
                                      opacity: active ? 1 : .45,
                                      child: Image.asset(
                                        'assets/monitor/station.png',
                                        width: 32,
                                        height: 32,
                                        cacheWidth: 96,
                                        excludeFromSemantics: true,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Tooltip(
                                        message: station,
                                        child: Text(
                                          station,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: active
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            color: active
                                                ? const Color(0xffdefaff)
                                                : const Color(0xff9db8cc),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (active)
                                      const Icon(
                                        Icons.chevron_right,
                                        size: 16,
                                        color: Color(0xff7de5ff),
                                      )
                                    else
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 2,
                                        ),
                                        child: Text(
                                          '${stations.indexOf(station) + 1}'
                                              .padLeft(2, '0'),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: Color(0xff42647f),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(width: 9),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(14, 10, 14, 16),
            padding: const EdgeInsets.only(top: 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xff19394f))),
            ),
            child: const Row(
              children: [
                Icon(Icons.layers_outlined, size: 14, color: Color(0xff50748e)),
                SizedBox(width: 7),
                Text(
                  '站点独立视图',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1,
                    color: Color(0xff6689a2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MonitorClock extends StatefulWidget {
  const _MonitorClock({required this.showGis});
  final bool showGis;
  @override
  State<_MonitorClock> createState() => _MonitorClockState();
}

class _MonitorClockState extends State<_MonitorClock> {
  late final Timer timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return SizedBox(
      width: 102,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
              maxLines: 1,
              style: TextStyle(
                color: widget.showGis
                    ? const Color(0xffcbe9f8)
                    : ProcessStyle.ink,
                fontSize: 19,
                letterSpacing: 1.7,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${now.year} / ${two(now.month)} / ${two(now.day)}',
              maxLines: 1,
              style: TextStyle(
                color: widget.showGis
                    ? const Color(0xff779db9)
                    : ProcessStyle.muted,
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
