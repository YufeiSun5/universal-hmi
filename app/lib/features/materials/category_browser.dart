import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'session.dart';
import 'widgets.dart';
import 'category_tree.dart';

/// Paged roots and paged descendants remain independently reachable. Search
/// returns full paths, so identical leaf names retain their ancestor context.
class MaterialCategoryBrowser extends StatefulWidget {
  const MaterialCategoryBrowser({
    super.key,
    required this.api,
    required this.session,
    required this.onSelect,
    this.revision = 0,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final ValueChanged<Json?> onSelect;
  final int revision;
  @override
  State<MaterialCategoryBrowser> createState() =>
      _MaterialCategoryBrowserState();
}

class _MaterialCategoryBrowserState extends State<MaterialCategoryBrowser> {
  final search = TextEditingController();
  List<Json> roots = [];
  int total = 0, generation = 0;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant MaterialCategoryBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    final token = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '$materialsBase/categories',
        query: {
          'search': search.text.trim(),
          if (search.text.trim().isEmpty) 'parent_id': '',
          'limit': 50,
          'offset': more ? roots.length : 0,
        },
      );
      if (!mounted || token != generation) return;
      setState(() {
        roots = [if (more) ...roots, ...objects(result['items'])];
        total = result['total'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    }
    if (mounted && token == generation) setState(() => busy = false);
  }

  void expand(bool value) {
    widget.session.categoryDefaultExpanded = value;
    widget.session.categorySeen.clear();
    widget.session.categoryExpanded.clear();
    setState(() => generation++);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '按分类筛选',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '全部展开',
              onPressed: busy ? null : () => expand(true),
              icon: const Icon(Icons.unfold_more, size: 18),
            ),
            IconButton(
              tooltip: '全部收起',
              onPressed: busy ? null : () => expand(false),
              icon: const Icon(Icons.unfold_less, size: 18),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: TextField(
          key: const ValueKey('materials-category-search'),
          controller: search,
          decoration: InputDecoration(
            labelText: '搜索分类',
            isDense: true,
            suffixIcon: IconButton(
              tooltip: '搜索分类',
              onPressed: busy ? null : load,
              icon: const Icon(Icons.search, size: 18),
            ),
          ),
          onSubmitted: (_) => load(),
        ),
      ),
      TextButton.icon(
        onPressed: () => widget.onSelect(null),
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('全部分类'),
      ),
      if (busy) const LinearProgressIndicator(minHeight: 2),
      if (error != null) materialError(error!, retry: load),
      Expanded(
        child: MaterialCategoryTree(
          key: ValueKey('sidebar-tree-$generation'),
          api: widget.api,
          roots: roots,
          session: widget.session,
          selectedID: widget.session.selectedCategory?['id'] as String?,
          searchResults: search.text.trim().isNotEmpty,
          onSelect: widget.onSelect,
        ),
      ),
      if (roots.length < total)
        TextButton(
          onPressed: busy ? null : () => load(more: true),
          child: Text('更多分类（${roots.length}/$total）'),
        ),
    ],
  );
}

Future<bool?> changeMaterialCategoryDeletion(
  BuildContext context,
  PlatformApi api,
  MaterialsSession session,
  Json category, {
  ValueChanged<String>? onDependency,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DeletionDialog(
    api: api,
    session: session,
    category: category,
    onDependency: onDependency,
  ),
);

class _DeletionDialog extends StatefulWidget {
  const _DeletionDialog({
    required this.api,
    required this.session,
    required this.category,
    this.onDependency,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json category;
  final ValueChanged<String>? onDependency;
  @override
  State<_DeletionDialog> createState() => _DeletionDialogState();
}

class _DeletionDialogState extends State<_DeletionDialog> {
  Json? state;
  String? error;
  bool busy = false;
  late final path =
      '$materialsBase/categories/${widget.category['id']}/deletion';
  late final draft = widget.session.draft(
    'category-deletion-${widget.category['id']}',
  );
  bool get restore => widget.category['deleted'] == true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.api.request('GET', path);
      if (mounted) setState(() => state = value);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await draft.submit(widget.api, path, {
        'version': state!['category']['version'],
        'deleted': !restore,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(restore ? '恢复分类' : '删除分类'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              categoryLabel(widget.category),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              restore
                  ? '恢复后可以用于新业务。父分类须已恢复，且同层不能有同名分类。'
                  : '删除后移入“已删除”，可恢复。历史单据、签名和库存账继续保留。',
            ),
            if (busy) const LinearProgressIndicator(),
            if (state != null && !restore)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '有效子分类：${state!['children']}\n在用物料档案：${state!['items']}\n非零库存：${state!['balances']}\n${state!['can_delete'] == true ? '可以删除此分类。' : '请先处理上述依赖；不会连带删除任何资料或库存。'}',
                ),
              ),
            if (draft.pending != null) const Text('操作结果待确认，重试沿用同一操作，不会重复执行。'),
            if (state != null &&
                !restore &&
                widget.onDependency != null &&
                draft.pending == null)
              Wrap(
                spacing: 8,
                children: [
                  for (final target in ['children', 'items', 'balances'])
                    if ((state![target] as int? ?? 0) > 0)
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () {
                                Navigator.pop(context, false);
                                widget.onDependency!(target);
                              },
                        child: Text(
                          const {
                            'children': '查看子分类',
                            'items': '查看物料档案',
                            'balances': '查看分类库存',
                          }[target]!,
                        ),
                      ),
                ],
              ),
            if (error != null)
              materialError(error!, retry: draft.pending == null ? load : null),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('返回'),
      ),
      FilledButton(
        onPressed:
            busy ||
                state == null ||
                (!restore &&
                    state!['can_delete'] != true &&
                    draft.pending == null)
            ? null
            : save,
        child: Text(
          draft.pending != null
              ? '重试确认结果'
              : restore
              ? '确认恢复'
              : '确认删除',
        ),
      ),
    ],
  );
}
