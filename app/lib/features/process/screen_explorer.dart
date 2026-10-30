import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';
import 'create_screen.dart';
import 'copy_screen.dart';
import 'model.dart';
import 'monitor_theme.dart';
import 'page_navigation.dart';

/// Activities select the adjacent sidebar only; documents open from that panel.
class WorkspaceActivityRail extends StatelessWidget {
  const WorkspaceActivityRail({
    super.key,
    required this.selectedPanel,
    required this.onSelect,
    this.expanded = true,
    this.onSecurity,
  });
  final int selectedPanel;
  final bool expanded;
  final ValueChanged<int> onSelect;
  final VoidCallback? onSecurity;
  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    color: const Color(0xfff2f4f8),
    child: Column(
      children: [
        const SizedBox(height: 8),
        for (final (index, icon, title) in const [
          (0, Icons.account_tree_outlined, '资源管理器'),
          (1, Icons.view_quilt_outlined, '运行与历史'),
          (2, Icons.compare_arrows, '跨站比较'),
          (3, Icons.router_outlined, '采集来源'),
          (4, Icons.dataset_linked_outlined, '外数据'),
          (5, Icons.inventory_2_outlined, '设备台账'),
        ])
          Container(
            height: 44,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 2,
                  color: selectedPanel == index && expanded
                      ? const Color(0xff2878d0)
                      : Colors.transparent,
                ),
              ),
            ),
            child: IconButton(
              tooltip: title,
              onPressed: () => onSelect(index),
              icon: Icon(
                icon,
                size: 21,
                color: selectedPanel == index && expanded
                    ? const Color(0xff2878d0)
                    : const Color(0xff66758b),
              ),
            ),
          ),
        const Spacer(),
        if (onSecurity != null)
          SizedBox(
            height: 44,
            child: IconButton(
              tooltip: '权限配置',
              onPressed: onSecurity,
              icon: const Icon(
                Icons.manage_accounts_outlined,
                size: 21,
                color: Color(0xff66758b),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Same saved documents in user and developer mode; only developer mode writes.
class ScreenExplorer extends StatefulWidget {
  const ScreenExplorer({
    super.key,
    required this.api,
    required this.stations,
    required this.station,
    required this.onStation,
    required this.onOpen,
    this.onAddStation,
    this.onDeleteStation,
    this.onAddScreen,
    this.onVariables,
    this.onPreview,
    this.selectedID,
    this.kindFilter,
    this.development = false,
    this.canWrite = false,
    this.refreshRevision = 0,
  });
  final VoidCallback? onAddStation;
  final ValueChanged<String>? onDeleteStation;
  final ValueChanged<String>? onAddScreen;
  final ValueChanged<String>? onVariables;
  final ValueChanged<Json>? onPreview;
  final PlatformApi api;
  final List<String> stations;
  final String station;
  final String? selectedID, kindFilter;
  final bool development, canWrite;
  final int refreshRevision;
  final ValueChanged<String> onStation;
  final ValueChanged<Json> onOpen;
  @override
  State<ScreenExplorer> createState() => _ScreenExplorerState();
}

class _ScreenExplorerState extends State<ScreenExplorer> {
  List<Json> documents = [];
  Json? navigation;
  String query = '';
  String? error;
  bool loading = true;
  final collapsed = <String>{};
  final search = TextEditingController();
  int generation = 0;
  final copying = <String>{};
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant ScreenExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A runtime process selection changes the highlight, not the catalog.
    // Keep the existing tree (and its scroll/search state) while the canvas opens.
    if (oldWidget.refreshRevision != widget.refreshRevision ||
        oldWidget.api != widget.api ||
        oldWidget.development != widget.development ||
        oldWidget.kindFilter != widget.kindFilter ||
        (oldWidget.selectedID != widget.selectedID &&
            (widget.development || widget.kindFilter != 'process'))) {
      reload();
    }
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final request = ++generation;
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/screens',
        query: {'all': true},
      );
      final menu = widget.development
          ? null
          : await widget.api.request('GET', '/api/v1/navigation');
      if (!mounted || request != generation) return;
      setState(() {
        documents = objects(result['items']);
        navigation = menu;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          loading = false;
          error = '画面目录读取失败';
        });
      }
    }
  }

  Future<void> add(String scope) async {
    if (widget.onAddScreen != null) {
      widget.onAddScreen!(scope);
      return;
    }
    final created = await addScreen(context, widget.api, scope);
    if (!mounted || created == null) return;
    await reload();
    if (mounted) widget.onOpen(created);
  }

  Future<void> copyScreen(Json summary) async {
    final id = summary['id'] as String;
    if (!widget.development || !widget.canWrite || !copying.add(id)) return;
    setState(() {});
    try {
      final source = ScreenDocument.fromJson(
        await widget.api.request('GET', '/api/v1/screens/$id'),
      );
      if (!mounted) return;
      final next = await copyProcessScreen(
        context,
        widget.api,
        source,
        widget.stations,
      );
      if (next == null || !mounted) return;
      await reload();
      if (mounted) widget.onOpen(next.toJson());
    } catch (e) {
      if (mounted) setState(() => error = '复制画面读取失败：$e');
    } finally {
      copying.remove(id);
      if (mounted) setState(() {});
    }
  }

  List<Json> get visibleDocuments => documents
      .where(
        (d) =>
            widget.kindFilter == null ||
            (d['kind'] ?? 'process') == widget.kindFilter,
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final scopes = {
      ...widget.stations,
      ...visibleDocuments.map((d) => d['station'] as String),
    }..remove('');
    final ordered = scopes.toList()..sort();
    if (!widget.development) return runtimeMenu(ordered);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.development
                        ? '画面资源'
                        : widget.kindFilter == 'process'
                        ? '工艺图'
                        : '站点地图',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.development && widget.canWrite)
                  IconButton(
                    tooltip: '页面导航配置',
                    onPressed: loading
                        ? null
                        : () async {
                            await editPageNavigation(
                              context,
                              widget.api,
                              documents,
                            );
                            if (mounted) await reload();
                          },
                    icon: const Icon(Icons.menu_open, size: 18),
                  ),
                if (widget.development && widget.canWrite)
                  IconButton(
                    tooltip: '新建站点',
                    onPressed: widget.onAddStation,
                    icon: const Icon(Icons.add, size: 17),
                  ),
                IconButton(
                  tooltip: '刷新画面目录',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh, size: 16),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SizedBox(
              height: 30,
              child: TextField(
                key: const Key('monitor-station-search'),
                controller: search,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '搜索站点 / 画面',
                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                  isDense: true,
                ),
                onChanged: (v) =>
                    setState(() => query = v.trim().toLowerCase()),
              ),
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 1),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                error!,
                style: const TextStyle(
                  color: MonitorColors.warning,
                  fontSize: 11,
                ),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (widget.development ||
                    widget.kindFilter != 'process' ||
                    visibleDocuments.any((d) => d['station'] == ''))
                  group(''),
                for (final scope in ordered) group(scope),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              widget.development ? 'GIS 公共驾驶舱 · 工艺布局跨站复用' : '运行监视',
              style: const TextStyle(fontSize: 10, color: MonitorColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget runtimeMenu(List<String> scopes) => DesktopSidebar(
    title: '工艺目录',
    actions: [
      IconButton(
        tooltip: '刷新画面目录',
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        padding: EdgeInsets.zero,
        onPressed: reload,
        icon: const Icon(Icons.refresh, size: 16, color: DesktopSidebar.muted),
      ),
    ],
    search: DesktopSidebarSearch(
      fieldKey: const Key('monitor-station-search'),
      controller: search,
      hint: '搜索站点 / 画面',
      onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 1),
        if (error != null)
          TextButton(onPressed: reload, child: Text('$error · 重试')),
        Expanded(
          child: loading || error != null
              ? const SizedBox.shrink()
              : PageNavigationTree(
                  nodes: navigation?['enabled'] == true
                      ? objects(navigation?['nodes'])
                      : [
                          for (final scope in [
                            if (visibleDocuments.any((d) => d['station'] == ''))
                              '',
                            ...scopes,
                          ])
                            {
                              'id': 'scope-$scope',
                              'label': scope.isEmpty ? '公共画面' : scope,
                              'children': [
                                for (final d in visibleDocuments.where(
                                  (d) => d['station'] == scope,
                                ))
                                  {
                                    'id': 'screen-${d['id']}',
                                    'label': d['name'],
                                    'screen_id': d['id'],
                                  },
                              ],
                            },
                        ],
                  screens: navigation?['enabled'] == true
                      ? documents
                      : visibleDocuments,
                  selectedID: widget.selectedID,
                  query: query,
                  onOpen: widget.onOpen,
                ),
        ),
      ],
    ),
  );

  Widget group(String scope) {
    final label = scope.isEmpty ? '公共画面' : scope;
    final matchesScope = label.toLowerCase().contains(query);
    final pages = visibleDocuments
        .where(
          (d) =>
              d['station'] == scope &&
              (matchesScope ||
                  d['name'].toString().toLowerCase().contains(query)),
        )
        .toList();
    if (query.isNotEmpty && !matchesScope && pages.isEmpty) {
      return const SizedBox();
    }
    final open = !collapsed.contains(scope) || query.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 32,
          child: InkWell(
            key: Key(
              widget.development
                  ? (scope.isEmpty ? 'station-global' : 'station-$scope')
                  : 'monitor-station-$scope',
            ),
            onTap: () => widget.onStation(scope),
            child: Row(
              children: [
                IconButton(
                  tooltip: open ? '折叠 $label' : '展开 $label',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 28,
                  ),
                  onPressed: () => setState(() {
                    if (open) {
                      collapsed.add(scope);
                    } else {
                      collapsed.remove(scope);
                    }
                  }),
                  icon: Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 17,
                  ),
                ),
                Icon(
                  scope.isEmpty ? Icons.folder_open : Icons.home_work_outlined,
                  size: 15,
                  color: MonitorColors.cyan,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scope == widget.station
                          ? Theme.of(context).colorScheme.onSurface
                          : MonitorColors.muted,
                    ),
                  ),
                ),
                if (widget.canWrite)
                  IconButton(
                    tooltip: scope.isEmpty ? '新建公共画面' : '为 $scope 添加画面',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    onPressed: () => add(scope),
                    icon: const Icon(Icons.add, size: 17),
                  ),
                if (widget.canWrite &&
                    scope.isNotEmpty &&
                    widget.onDeleteStation != null)
                  IconButton(
                    tooltip: '删除站点 $scope',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    onPressed: () => widget.onDeleteStation!(scope),
                    icon: const Icon(Icons.delete_outline, size: 16),
                  ),
              ],
            ),
          ),
        ),
        if (open) ...[
          if (scope.isNotEmpty && widget.onVariables != null)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 34, right: 8),
              title: const Text('变量与采集', style: TextStyle(fontSize: 12)),
              leading: const Icon(Icons.data_object, size: 16),
              onTap: () => widget.onVariables!(scope),
            ),
          for (final d in pages) leaf(d),
          if (pages.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(34, 2, 8, 6),
              child: Text(
                widget.development ? '尚未添加画面' : '暂无可用画面',
                style: const TextStyle(
                  fontSize: 10,
                  color: MonitorColors.muted,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget leaf(Json d) {
    final selected = widget.selectedID == d['id'];
    return Semantics(
      selected: selected,
      child: Container(
        height: widget.development ? 30 : 36,
        color: selected
            ? (Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xff164468)
                  : Theme.of(context).colorScheme.primaryContainer)
            : Colors.transparent,
        child: InkWell(
          key: Key('screen-resource-${d['id']}'),
          onTap: () => widget.onOpen(d),
          child: Padding(
            padding: const EdgeInsets.only(left: 32, right: 6),
            child: Row(
              children: [
                Icon(
                  d['kind'] == 'gis'
                      ? Icons.public
                      : Icons.account_tree_outlined,
                  size: 15,
                  color: selected ? MonitorColors.cyan : MonitorColors.muted,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    d['name'].toString(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (widget.development && widget.onPreview != null)
                  IconButton(
                    tooltip: '预览 ${d['name']}',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    onPressed: () => widget.onPreview!(d),
                    icon: const Icon(Icons.play_circle_outline, size: 16),
                  ),
                if (widget.development && widget.canWrite && d['kind'] != 'gis')
                  IconButton(
                    key: Key('copy-screen-${d['id']}'),
                    tooltip: '复制工艺图',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    onPressed: copying.contains(d['id'])
                        ? null
                        : () => copyScreen(d),
                    icon: const Icon(Icons.copy_outlined, size: 15),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
