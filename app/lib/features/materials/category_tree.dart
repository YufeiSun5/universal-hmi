import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'session.dart';
import 'widgets.dart';

/// Each expanded branch fetches its own page. Catalog size is not limited to
/// the first page, and opening a branch never downloads the entire warehouse.
class MaterialCategoryTree extends StatefulWidget {
  const MaterialCategoryTree({
    super.key,
    required this.api,
    required this.roots,
    required this.session,
    required this.onEdit,
    required this.onAdd,
  });
  final PlatformApi api;
  final List<Json> roots;
  final MaterialsSession session;
  final ValueChanged<Json> onEdit, onAdd;
  @override
  State<MaterialCategoryTree> createState() => _MaterialCategoryTreeState();
}

class _MaterialCategoryTreeState extends State<MaterialCategoryTree> {
  final children = <String, List<Json>>{};
  final totals = <String, int>{};
  final busy = <String>{};
  final errors = <String, String>{};
  late final ScrollController scroll = ScrollController(
    initialScrollOffset: widget.session.offsets['category-tree'] ?? 0,
  )..addListener(() => widget.session.offsets['category-tree'] = scroll.offset);
  @override
  void initState() {
    super.initState();
    restore(widget.roots);
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> restore(List<Json> nodes) async {
    for (final node in nodes) {
      if (!mounted) return;
      if (widget.session.categoryExpanded.contains(materialText(node, 'id'))) {
        await load(node);
      }
    }
  }

  Future<void> load(Json parent, {bool more = false}) async {
    final id = materialText(parent, 'id');
    if (busy.contains(id)) return;
    setState(() {
      busy.add(id);
      errors.remove(id);
    });
    try {
      final result = await widget.api.request(
        'GET',
        '$materialsBase/categories',
        query: {
          'parent_id': id,
          'offset': more ? (children[id]?.length ?? 0) : 0,
          'limit': 50,
        },
      );
      if (!mounted) return;
      final nodes = objects(result['items']);
      setState(() {
        children[id] = [if (more) ...?children[id], ...nodes];
        totals[id] = result['total'] as int? ?? 0;
      });
      await restore(nodes);
    } catch (e) {
      if (mounted) setState(() => errors[id] = '$e');
    }
    if (mounted) setState(() => busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.roots.isEmpty) return const Center(child: Text('暂无记录'));
    final rows = <({Json node, int depth, bool more})>[];
    void append(List<Json> nodes, int depth) {
      for (final node in nodes) {
        rows.add((node: node, depth: depth, more: false));
        final id = materialText(node, 'id');
        if (widget.session.categoryExpanded.contains(id)) {
          append(children[id] ?? [], depth + 1);
          if (busy.contains(id) ||
              errors.containsKey(id) ||
              (children[id]?.length ?? 0) < (totals[id] ?? 0)) {
            rows.add((node: node, depth: depth + 1, more: true));
          }
        }
      }
    }

    append(widget.roots, 0);
    return ListView.builder(
      controller: scroll,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final node = row.node;
        final id = materialText(node, 'id');
        if (row.more) {
          return Padding(
            padding: EdgeInsets.only(
              left: math.min(row.depth * 16.0, 64),
              right: 12,
            ),
            child: busy.contains(id)
                ? const LinearProgressIndicator()
                : errors.containsKey(id)
                ? materialError(
                    errors[id]!,
                    retry: () => load(node, more: children.containsKey(id)),
                  )
                : TextButton(
                    onPressed: () => load(node, more: true),
                    child: Text(
                      '更多子分类（${children[id]?.length ?? 0}/${totals[id]}）',
                    ),
                  ),
          );
        }
        final expanded = widget.session.categoryExpanded.contains(id);
        return Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xffe1e5e9))),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: math.min(row.depth * 16.0, 64),
              right: 8,
            ),
            child: Row(
              children: [
                IconButton(
                  key: ValueKey('category-expand-$id'),
                  tooltip: expanded ? '收起子分类' : '展开子分类',
                  onPressed: (node['children'] as int? ?? 0) == 0
                      ? null
                      : () {
                          setState(() {
                            if (expanded) {
                              widget.session.categoryExpanded.remove(id);
                            } else {
                              widget.session.categoryExpanded.add(id);
                            }
                          });
                          if (!expanded && !children.containsKey(id)) {
                            load(node);
                          }
                        },
                  icon: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                  ),
                ),
                Expanded(
                  child: Tooltip(
                    message: categoryLabel(node),
                    child: InkWell(
                      onTap: () => widget.onEdit(node),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          '${node['name']}  · 第${row.depth + 1}层',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '添加子分类',
                  onPressed: row.depth >= 9 ? null : () => widget.onAdd(node),
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                IconButton(
                  tooltip: '编辑分类',
                  onPressed: () => widget.onEdit(node),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
