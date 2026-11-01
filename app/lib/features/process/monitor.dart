import 'package:flutter/material.dart';
import '../../platform/pointer_shield.dart';
import '../../shared/api.dart';
import 'gis_screen.dart';
import 'diagram.dart';
import 'model.dart';
import 'monitor_theme.dart';
import 'monitor_chrome.dart';
import 'dart:async';
import 'screen_explorer.dart';
import 'runtime_chrome.dart';
import 'subscriptions.dart';

/// Presentation shell only. Station membership and live values come from the
/// workspace; all document reads go through its authenticated API client.
class HeatingMonitor extends StatefulWidget {
  const HeatingMonitor({
    super.key,
    required this.api,
    required this.stations,
    required this.station,
    required this.onStationChanged,
    required this.onNavigate,
    required this.definitions,
    required this.live,
    required this.online,
    this.username,
    this.onLogout,
    this.onSecurity,
    this.onAccount,
    this.error,
    this.showGis = false,
    this.development = false,
    this.canWrite = false,
    this.editor,
    this.activeScreen,
    this.onOpenScreen,
    this.activePage = 9,
    this.userContent,
    this.userSidebarBuilder,
    this.selectedScreens = const {},
    this.onScreenSelected,
    this.onSubscriptionChanged,
  });
  final ValueChanged<Set<String>>? onSubscriptionChanged;
  final PlatformApi api;
  final List<String> stations;
  final String station;
  final ValueChanged<String> onStationChanged;
  final ValueChanged<int> onNavigate;
  final Map<String, Json> definitions, live;
  final bool online;
  final bool showGis, development, canWrite;
  final Widget? editor, userContent;

  /// Optional client directory; selection can close the shared narrow drawer.
  final Widget Function(VoidCallback closeDrawer)? userSidebarBuilder;
  final int activePage;
  final Json? activeScreen;
  final ValueChanged<Json>? onOpenScreen;
  final String? username, error;
  final VoidCallback? onLogout;
  final VoidCallback? onSecurity;
  final VoidCallback? onAccount;
  final Map<String, String> selectedScreens;
  final void Function(String station, String screen)? onScreenSelected;

  @override
  State<HeatingMonitor> createState() => _HeatingMonitorState();
}

class _HeatingMonitorState extends State<HeatingMonitor> {
  final shellKey = GlobalKey<ScaffoldState>();
  final search = TextEditingController();
  String query = '';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<String> get stations =>
      widget.stations.where((s) => s.isNotEmpty).toSet().toList()..sort();
  String get selected => widget.station;

  Widget header(bool compact) => Theme(
    data: MonitorColors.theme(Theme.of(context)),
    child: MonitorHeader(
      compact: compact,
      showGis: widget.showGis,
      activePage: widget.activePage,
      onNavigate: widget.onNavigate,
      username: widget.username,
      onLogout: widget.onLogout,
      onSecurity: widget.onSecurity,
      onAccount: widget.onAccount,
    ),
  );

  bool treeVisible = true;
  bool get hasSidebar =>
      widget.userSidebarBuilder != null ||
      !const [12, 13].contains(widget.activePage);
  Widget sidebar() =>
      widget.userSidebarBuilder?.call(
        () => shellKey.currentState?.closeDrawer(),
      ) ??
      Theme(data: ProcessStyle.theme(Theme.of(context)), child: stationList());
  Widget stationList() => ScreenExplorer(
    api: widget.api,
    kindFilter: widget.showGis ? 'gis' : 'process',
    stations: stations,
    station:
        widget.activeScreen?['station'] as String? ??
        (widget.showGis ? '' : widget.station),
    development: widget.development,
    canWrite: widget.canWrite,
    selectedID:
        widget.activeScreen?['id'] as String? ??
        (widget.showGis ? '' : widget.selectedScreens[selected]),
    onStation: widget.onStationChanged,
    onOpen: (d) {
      shellKey.currentState?.closeDrawer();
      if (widget.onOpenScreen != null) {
        widget.onOpenScreen!(d);
        return;
      }
      if (d['kind'] == 'gis') {
        widget.onNavigate(11);
      } else {
        widget.onStationChanged(d['station'] as String);
        widget.onScreenSelected?.call(
          d['station'] as String,
          d['id'] as String,
        );
      }
    },
  );

  @override
  Widget build(BuildContext context) {
    final scope =
        widget.activeScreen?['station'] as String? ??
        (widget.showGis ? '' : selected);
    final gis =
        widget.activeScreen?['kind'] == 'gis' ||
        (widget.activeScreen == null && widget.showGis);
    final title =
        const {12: '历史', 13: '设备台账'}[widget.activePage] ??
        widget.activeScreen?['name']?.toString() ??
        (gis ? '首页 GIS' : '工艺画面');
    return Theme(
      data: gis
          ? MonitorColors.theme(Theme.of(context))
          : RuntimeStyle.theme(Theme.of(context)),
      child: Scaffold(
        key: shellKey,
        backgroundColor: gis ? MonitorColors.background : RuntimeStyle.paper,
        drawer: !gis && hasSidebar
            ? Drawer(width: 280, child: SafeArea(child: sidebar()))
            : null,
        body: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => gis && !widget.development
                    ? Stack(
                        children: [
                          Positioned.fill(
                            child: GisScreen(
                              onSubscriptionChanged:
                                  widget.onSubscriptionChanged,
                              onOpenScreen: widget.onOpenScreen,
                              definitions: widget.definitions,
                              live: widget.live,
                              online: widget.online,
                              key: ValueKey(
                                'gis-${widget.activeScreen?['id'] ?? 'home'}',
                              ),
                              api: widget.api,
                              summary: widget.activeScreen,
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: PlatformPointerShield(
                              child: header(box.maxWidth < 1100),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          if (widget.development)
                            Container(
                              height: 36,
                              color: MonitorColors.header,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.design_services_outlined,
                                    size: 16,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    '开发工作台',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Text(
                                    '公共 · 画面与模板',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: MonitorColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            header(box.maxWidth < 1100),
                          Expanded(
                            child: Row(
                              children: [
                                if (widget.development || box.maxWidth >= 900)
                                  Offstage(
                                    offstage: !treeVisible || !hasSidebar,
                                    child: SizedBox(
                                      width: 249,
                                      child: Row(
                                        children: [
                                          Expanded(child: sidebar()),
                                          const VerticalDivider(
                                            width: 1,
                                            color: ProcessStyle.line,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (!widget.development &&
                                          widget.activePage != 13)
                                        RuntimeHeading(
                                          process: widget.activePage == 9,
                                          title: title,
                                          subtitle:
                                              const {
                                                12: '外部历史查询与分析',
                                                13: '设备档案 · 技术参数 · 实时状态',
                                              }[widget.activePage] ??
                                              (scope.isEmpty
                                                  ? '站点与公共画面'
                                                  : scope),
                                          online: widget.online,
                                          onMenu: !hasSidebar
                                              ? null
                                              : () {
                                                  if (box.maxWidth < 900) {
                                                    shellKey.currentState
                                                        ?.openDrawer();
                                                  } else {
                                                    setState(
                                                      () => treeVisible =
                                                          !treeVisible,
                                                    );
                                                  }
                                                },
                                        ),
                                      if (widget.development)
                                        Container(
                                          height: 34,
                                          color: MonitorColors.header
                                              .withValues(alpha: .4),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                gis
                                                    ? Icons.public
                                                    : Icons
                                                          .account_tree_outlined,
                                                size: 15,
                                              ),
                                              const SizedBox(width: 7),
                                              Expanded(
                                                child: Text(
                                                  '${scope.isEmpty ? '公共画面' : scope} / $title',
                                                  key: const Key(
                                                    'monitor-current-station',
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                              if (box.maxWidth > 700)
                                                Text(
                                                  widget.online
                                                      ? '实时已连接'
                                                      : '连接已中断',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: widget.online
                                                        ? MonitorColors.muted
                                                        : MonitorColors.warning,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      if (widget.error != null ||
                                          !widget.online)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          child: Text(
                                            widget.error ?? '连接已中断，实时数据不可用',
                                            maxLines: 2,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xffb04436),
                                            ),
                                          ),
                                        ),
                                      Expanded(
                                        child:
                                            widget.userContent ??
                                            (widget.development &&
                                                    !gis &&
                                                    widget.editor != null
                                                ? widget.editor!
                                                : gis
                                                ? GisScreen(
                                                    onOpenScreen:
                                                        widget.onOpenScreen,
                                                    definitions:
                                                        widget.definitions,
                                                    live: widget.live,
                                                    online: widget.online,
                                                    key: ValueKey(
                                                      'gis-${widget.activeScreen?['id'] ?? 'home'}',
                                                    ),
                                                    api: widget.api,
                                                    onSubscriptionChanged: widget
                                                        .onSubscriptionChanged,
                                                    summary:
                                                        widget.activeScreen,
                                                  )
                                                : (selected.isEmpty &&
                                                      scope.isNotEmpty)
                                                ? const Center(
                                                    child: Text('尚未配置站点'),
                                                  )
                                                : StationProcessView(
                                                    key: ValueKey(
                                                      'monitor-screen-$scope-${widget.activeScreen?['id'] ?? ''}',
                                                    ),
                                                    api: widget.api,
                                                    onSubscriptionChanged: widget
                                                        .onSubscriptionChanged,
                                                    station: scope,
                                                    definitions:
                                                        widget.definitions,
                                                    live: widget.live,
                                                    online: widget.online,
                                                    canvasOnly:
                                                        !widget.development,
                                                    initialScreenID:
                                                        widget.activeScreen?['id']
                                                            as String? ??
                                                        widget
                                                            .selectedScreens[scope],
                                                    onSelected: (id) => widget
                                                        .onScreenSelected
                                                        ?.call(scope, id),
                                                  )),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (widget.development)
                            Container(
                              height: 22,
                              color: MonitorColors.header,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.development
                                          ? '开发模式 · 保存画面不改变采集配置'
                                          : '用户画面 · 只读展示',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: MonitorColors.muted,
                                      ),
                                    ),
                                  ),
                                  if (!gis && box.maxWidth > 600)
                                    const Text(
                                      '箭头表示设计流向',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: MonitorColors.muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loads saved documents without touching editor drafts or issuing writes.
class StationProcessView extends StatefulWidget {
  const StationProcessView({
    super.key,
    required this.api,
    required this.station,
    required this.definitions,
    required this.live,
    required this.online,
    this.initialScreenID,
    this.onSelected,
    this.canvasOnly = false,
    this.onSubscriptionChanged,
  });
  final PlatformApi api;
  final String station;
  final Map<String, Json> definitions, live;
  final bool online;
  final String? initialScreenID;
  final ValueChanged<String>? onSelected;
  final bool canvasOnly;
  final ValueChanged<Set<String>>? onSubscriptionChanged;
  @override
  State<StationProcessView> createState() => _StationProcessViewState();
}

class _StationProcessViewState extends State<StationProcessView> {
  List<Json> screens = [];
  ScreenDocument? document;
  String? error;
  bool busy = true, syncing = false;
  Timer? layoutTimer;
  String? syncError;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
    layoutTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => checkLayout(),
    );
  }

  @override
  void dispose() {
    layoutTimer?.cancel();
    generation++;
    super.dispose();
  }

  Future<void> checkLayout() async {
    if (busy || syncing) return;
    syncing = true;
    final current = generation, previous = document;
    try {
      final index = objects(
        (await widget.api.request(
          'GET',
          '/api/v1/screens',
          query: {'station': widget.station},
        ))['items'],
      ).where((s) => s['kind'] != 'gis').toList();
      if (!mounted || current != generation) return;
      final latest = index.where((s) => s['id'] == previous?.id).firstOrNull;
      if (previous == null || latest == null) {
        if (index.isNotEmpty || previous != null) await load();
      } else if (latest['revision'] != previous.revision ||
          (latest['template_revision'] ?? 0) != previous.templateRevision) {
        final next = ScreenDocument.fromJson(
          await widget.api.request('GET', '/api/v1/screens/${previous.id}'),
        );
        if (!mounted || current != generation) return;
        setState(() {
          document = next;
          screens = index;
        });
        widget.onSubscriptionChanged?.call(processSubscriptionIDs(next));
      }
      if (mounted) setState(() => syncError = null);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => syncError = '布局同步失败，暂显示上次画面：$e');
      }
    } finally {
      syncing = false;
    }
  }

  @override
  void didUpdateWidget(covariant StationProcessView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.station != widget.station ||
        oldWidget.api != widget.api ||
        (oldWidget.initialScreenID != widget.initialScreenID &&
            widget.initialScreenID != document?.id)) {
      load();
    }
  }

  Future<void> load([String? id]) async {
    final current = ++generation, station = widget.station;
    setState(() {
      busy = true;
      error = null;
      document = null;
    });
    try {
      final items = id == null
          ? objects(
              (await widget.api.request(
                'GET',
                '/api/v1/screens',
                query: {'station': station},
              ))['items'],
            ).where((s) => s['kind'] != 'gis').toList()
          : screens;
      if (!mounted || current != generation) return;
      final preferred = widget.initialScreenID;
      final requested =
          id ??
          (items.any((s) => s['id'] == preferred)
              ? preferred
              : items.isEmpty
              ? null
              : items.first['id'] as String);
      final next = requested == null
          ? null
          : ScreenDocument.fromJson(
              await widget.api.request('GET', '/api/v1/screens/$requested'),
            );
      if (next != null && next.station != station) {
        throw const FormatException('画面不属于当前站点');
      }
      if (!mounted || current != generation) return;
      setState(() {
        screens = items;
        document = next;
        busy = false;
      });
      widget.onSubscriptionChanged?.call(processSubscriptionIDs(next));
      if (requested != null) widget.onSelected?.call(requested);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          error = '画面读取失败：$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (busy) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error!,
                style: const TextStyle(color: MonitorColors.warning),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (document == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 44,
                color: RuntimeStyle.muted,
              ),
              SizedBox(height: 18),
              Text(
                '暂无工艺画面',
                key: Key('monitor-empty-notice'),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text(
                '从目录选择其他画面，或联系工程师配置本站画面。',
                textAlign: TextAlign.center,
                style: TextStyle(color: RuntimeStyle.muted),
              ),
            ],
          ),
        ),
      );
    }
    final doc = document!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (syncError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              syncError!,
              style: const TextStyle(color: MonitorColors.warning),
            ),
          ),
        if (screens.length > 1 && !widget.canvasOnly)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<String>(
              key: const Key('monitor-screen-selector'),
              value: doc.id,
              isExpanded: true,
              items: [
                for (final s in screens)
                  DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text(
                      s['name'] as String,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id != null) load(id);
              },
            ),
          ),
        Expanded(
          child: ProcessDiagram(
            key: ValueKey(doc.id),
            document: doc,
            definitions: widget.definitions,
            live: widget.live,
            online: widget.online,
            compactUnboundValues: true,
            showControls: !widget.canvasOnly,
            title: doc.name,
          ),
        ),
      ],
    );
  }
}
