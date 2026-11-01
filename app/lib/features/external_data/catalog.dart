import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';

const externalKinds = {'hourly': '逐小时日报', 'detail': '历史明细', 'trend': '历史趋势'};
IconData externalIcon(String? kind) => switch (kind) {
  'hourly' => Icons.calendar_view_day_outlined,
  'trend' => Icons.show_chart,
  _ => Icons.table_chart_outlined,
};

class ExternalCatalog extends ChangeNotifier {
  ExternalCatalog(this.api, {required this.canDevelop});
  final PlatformApi api;
  final bool canDevelop;
  List<Json> sources = [], screens = [];
  bool loading = false, loaded = false, retired = false;
  String? error;
  Future<void> load() async {
    if (loading || retired) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await Future.wait([
        api.request('GET', '/api/v1/external/screens'),
        if (canDevelop) api.request('GET', '/api/v1/external/sources'),
      ]);
      if (retired) return;
      screens = objects(data[0]['items']);
      sources = canDevelop ? objects(data[1]['items']) : [];
      loaded = true;
    } catch (e) {
      if (!retired) error = e.toString();
    }
    if (!retired) {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    retired = true;
    super.dispose();
  }
}

class ExternalDataPanel extends StatefulWidget {
  const ExternalDataPanel({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.selectedID,
    this.searchController,
    this.development = false,
  });
  final ExternalCatalog catalog;
  final ValueChanged<Json?> onOpen;
  final String? selectedID;
  final TextEditingController? searchController;
  final bool development;
  @override
  State<ExternalDataPanel> createState() => _ExternalDataPanelState();
}

class _ExternalDataPanelState extends State<ExternalDataPanel> {
  String filter = '';
  @override
  void initState() {
    super.initState();
    if (!widget.catalog.loaded) {
      Future.microtask(widget.catalog.load);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.catalog, widget.searchController]),
    builder: (context, _) {
      final c = widget.catalog;
      final items = c.screens
          .where(
            (s) => '${s['name']}'.toLowerCase().contains(
              (widget.searchController?.text ?? filter).toLowerCase(),
            ),
          )
          .toList();
      if (!widget.development) {
        return DesktopSidebar(
          title: '历史目录',
          actions: [
            IconButton(
              tooltip: '刷新历史目录',
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              padding: EdgeInsets.zero,
              onPressed: c.loading ? null : c.load,
              icon: const Icon(
                Icons.refresh,
                size: 16,
                color: DesktopSidebar.muted,
              ),
            ),
          ],
          search: DesktopSidebarSearch(
            hint: '搜索查询画面',
            controller: widget.searchController,
            onChanged: (v) => setState(() => filter = v),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.loading) const LinearProgressIndicator(minHeight: 1),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    c.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          c.loading
                              ? '正在读取…'
                              : c.screens.isEmpty
                              ? '暂无已授权的历史画面。'
                              : '没有匹配的画面',
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final s = items[i];
                          return DesktopSidebarRow(
                            title: '${s['name']}',
                            tooltip:
                                "${s['name']} · ${externalKinds[s['kind']] ?? ''}",
                            icon: externalIcon(s['kind'] as String?),
                            selected: widget.selectedID == s['id'],
                            onTap: () => widget.onOpen(s),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '外数据',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '刷新外数据目录',
                  onPressed: c.loading ? null : c.load,
                  icon: const Icon(Icons.refresh, size: 17),
                ),
              ],
            ),
          ),
          if (widget.development && c.canDevelop) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.dns_outlined, size: 18),
              title: const Text('数据源管理'),
              selected: widget.selectedID == null,
              onTap: () => widget.onOpen(null),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: c.loading || c.sources.isEmpty
                    ? null
                    : () async {
                        final result = await editExternalScreen(context, c);
                        if (result != null) widget.onOpen(result);
                      },
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加查询画面'),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              onChanged: (v) => setState(() => filter = v),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索查询画面',
                prefixIcon: Icon(Icons.search, size: 17),
              ),
            ),
          ),
          if (c.loading) const LinearProgressIndicator(minHeight: 2),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      c.loading
                          ? '正在读取…'
                          : c.screens.isEmpty
                          ? (widget.development
                                ? '先配置数据源，再添加查询画面。'
                                : '暂无已授权的外数据画面。')
                          : '没有匹配的画面',
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final s = items[i];
                      return ListTile(
                        dense: true,
                        selected: widget.selectedID == s['id'],
                        leading: Icon(
                          externalIcon(s['kind'] as String?),
                          size: 19,
                        ),
                        title: Text(
                          '${s['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          externalKinds[s['kind']] ?? '',
                          style: const TextStyle(fontSize: 10),
                        ),
                        onTap: () => widget.onOpen(s),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

Future<Json?> editExternalScreen(
  BuildContext context,
  ExternalCatalog catalog, [
  Json? screen,
]) => showDialog<Json>(
  context: context,
  builder: (_) => _ScreenEditor(catalog: catalog, screen: screen),
);

class _ScreenEditor extends StatefulWidget {
  const _ScreenEditor({required this.catalog, this.screen});
  final ExternalCatalog catalog;
  final Json? screen;
  @override
  State<_ScreenEditor> createState() => _ScreenEditorState();
}

class _ScreenEditorState extends State<_ScreenEditor> {
  late final name = TextEditingController(
    text: widget.screen?['name'] as String? ?? '逐小时日报',
  );
  late String source =
      widget.screen?['source_id'] as String? ??
      widget.catalog.sources.first['id'] as String;
  late String kind = widget.screen?['kind'] as String? ?? 'hourly';
  String? error;
  bool busy = false;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final s = await widget.catalog.api.request(
        'POST',
        '/api/v1/external/screens',
        body: {
          'id': widget.screen?['id'] ?? '',
          'revision': widget.screen?['revision'] ?? 0,
          'name': name.text.trim(),
          'source_id': source,
          'kind': kind,
        },
      );
      await widget.catalog.load();
      if (mounted) Navigator.pop(context, s);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.screen == null ? '添加外数据画面' : '编辑画面名称'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '画面名称'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: source,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '外部数据源'),
            items: widget.catalog.sources
                .map(
                  (s) => DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text('${s['name']}'),
                  ),
                )
                .toList(),
            onChanged: busy || widget.screen != null
                ? null
                : (v) => setState(() => source = v!),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: kind,
            decoration: const InputDecoration(labelText: '画面类型'),
            items: externalKinds.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: busy || widget.screen != null
                ? null
                : (v) => setState(() {
                    if (name.text == externalKinds[kind]) {
                      name.text = externalKinds[v]!;
                    }
                    kind = v!;
                  }),
          ),
          const SizedBox(height: 16),
          const Text(
            '画面独立于本站点。保存后，可在权限配置中授权给需要查看的用户。',
            style: TextStyle(fontSize: 12),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? '保存中…' : '保存画面'),
      ),
    ],
  );
}
