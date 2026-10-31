import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/variable_search.dart';
import 'controller.dart';
import 'model.dart';

/// Instance bindings, including authorized variables from other stations.
class ProcessBindingsPanel extends StatefulWidget {
  const ProcessBindingsPanel({
    super.key,
    required this.controller,
    required this.definitions,
    required this.enabled,
  });
  final ProcessController controller;
  final Map<String, Json> definitions;
  final bool enabled;
  @override
  State<ProcessBindingsPanel> createState() => _ProcessBindingsPanelState();
}

class _ProcessBindingsPanelState extends State<ProcessBindingsPanel> {
  String query = '';
  bool unboundOnly = false;
  Future<void> pick(ScreenElement node, String? ruleKey, int index) async {
    final document = widget.controller.document;
    final points = widget.definitions.values.toList();
    var filter = '';
    final id = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('选择工程内授权变量'),
          content: SizedBox(
            width: 540,
            height: 400,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '搜索变量：*、?、逗号多条件',
                  ),
                  onChanged: (v) =>
                      update(() => filter = v.trim().toLowerCase()),
                ),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final matches = points
                          .where(VariableSearch(filter).matchesPoint)
                          .toList();
                      return ListView.builder(
                        itemCount: matches.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return ListTile(
                              title: const Text('解除绑定'),
                              onTap: () => Navigator.pop(dialog, ''),
                            );
                          }
                          final p = matches[i - 1];
                          return ListTile(
                            title: Text('${p['name']}'),
                            subtitle: Text(
                              '${p['station'] ?? '公共'} · ${p['id']} · ${p['unit'] ?? ''}',
                            ),
                            onTap: () =>
                                Navigator.pop(dialog, p['id'].toString()),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        id == null ||
        !widget.enabled ||
        widget.controller.document.id != document.id) {
      return;
    }
    final current = widget.controller.document.nodes
        .where((n) => n.id == node.id)
        .firstOrNull;
    if (current == null) return;
    if (ruleKey == null) {
      widget.controller.update(current.update({'point_id': id}));
    } else {
      final rule = current.data[ruleKey] as Json;
      final conditions = objects(rule['conditions']);
      final target = conditions[index];
      widget.controller.update(
        current.update({
          ruleKey: {
            ...rule,
            'conditions': [
              for (final c in conditions)
                {
                  ...c,
                  if (c['slot'] == target['slot'] &&
                      c['operator'] == target['operator'] &&
                      c['value'] == target['value'])
                    'point_id': id,
                },
            ],
          },
        }),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rows = <(ScreenElement, String?, int, String, String)>[];
    for (final n in widget.controller.document.nodes) {
      final label = n.label.isNotEmpty
          ? n.label
          : n.text.isNotEmpty
          ? n.text
          : '${n.kind} · ${n.id.substring(0, n.id.length.clamp(0, 8))}';
      if (n.kind == 'value' || n.pointID.isNotEmpty || n.kind == 'symbol') {
        rows.add((n, null, 0, label, n.pointID));
      }
      for (final pair in [
        ('arrow_visible_rule', '显示'),
        ('arrow_motion_rule', '流动'),
      ]) {
        final rule = n.data[pair.$1] as Json?;
        if (rule == null) continue;
        final conditions = objects(rule['conditions']);
        for (var i = 0; i < conditions.length; i++) {
          final c = conditions[i];
          rows.add((
            n,
            pair.$1,
            i,
            '$label · ${pair.$2} · ${c['slot']} ${c['operator']} ${c['value']}',
            c['point_id'] as String? ?? '',
          ));
        }
      }
    }
    final filtered = rows
        .where(
          (r) =>
              (!unboundOnly || r.$5.isEmpty) &&
              '${r.$4} ${r.$5} ${widget.definitions[r.$5]?['name'] ?? ''}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '画面变量绑定 · ${rows.where((r) => r.$5.isNotEmpty).length}/${rows.length}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              hintText: '搜索绑定位置 / 变量',
            ),
            onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          ),
        ),
        CheckboxListTile(
          dense: true,
          title: const Text('只看未绑定'),
          value: unboundOnly,
          onChanged: (v) => setState(() => unboundOnly = v!),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.isEmpty ? 1 : filtered.length,
            itemBuilder: (context, i) {
              if (filtered.isEmpty) {
                return const ListTile(title: Text('没有符合条件的绑定位置'));
              }
              final r = filtered[i];
              final definition = widget.definitions[r.$5];
              return ListTile(
                dense: true,
                title: Text(r.$4),
                subtitle: Text(
                  r.$5.isEmpty
                      ? '未绑定'
                      : definition == null
                      ? '变量已不存在 · ${r.$5}'
                      : '${definition['station'] ?? '公共'} · ${definition['name']} · ${r.$5}',
                ),
                trailing: const Icon(Icons.link, size: 17),
                onTap: widget.enabled ? () => pick(r.$1, r.$2, r.$3) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
