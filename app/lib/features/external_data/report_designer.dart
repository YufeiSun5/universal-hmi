import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/report_style.dart';
import '../../shared/form_control_theme.dart';
import 'catalog.dart';

class ReportStyleHost extends StatefulWidget {
  const ReportStyleHost({super.key, required this.screen, required this.child});
  final Json screen;
  final Widget child;
  @override
  State<ReportStyleHost> createState() => _ReportStyleHostState();
}

class _ReportStyleHostState extends State<ReportStyleHost> {
  late final styles = ReportStyles(widget.screen);
  @override
  Widget build(BuildContext context) {
    styles.screen = widget.screen;
    return ReportStyleScope(styles: styles, child: widget.child);
  }
}

class ReportStyleAction extends StatelessWidget {
  const ReportStyleAction({
    super.key,
    required this.catalog,
    required this.screen,
    this.onSaved,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final ValueChanged<Json>? onSaved;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.palette_outlined, size: 18),
    label: const Text('报表样式'),
    onPressed: () async {
      final styles = ReportStyleScope.of(context)?.styles;
      if (styles == null) return;
      final schemas = Map<String, List<String>>.from(styles.schemas);
      final labels = Map<String, List<String>>.from(styles.labels);
      // A renamed SQL field can reject the query before a schema is registered.
      // Keep the saved layout reachable so it can be reset without recreating
      // the report or changing its authorization identity.
      final savedLayouts = screen['report_layouts'];
      if (schemas.isEmpty && savedLayouts is Map) {
        for (final entry in savedLayouts.entries) {
          if (entry.value is! Map) continue;
          final saved = objects(entry.value['columns']);
          if (saved.isEmpty) continue;
          schemas['${entry.key}'] = [for (final c in saved) '${c['key']}'];
          labels['${entry.key}'] = [for (final c in saved) '${c['label']}'];
        }
      }
      if (schemas.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先查询报表；同期对比可切换到汇总表后编辑样式')),
        );
        return;
      }
      final saved = await showDialog<Json>(
        context: context,
        builder: (_) => FormControlTheme(
          child: _StyleEditor(
            catalog: catalog,
            screen: screen,
            schemas: schemas,
            labels: labels,
          ),
        ),
      );
      if (saved != null) onSaved?.call(saved);
    },
  );
}

class _StyleEditor extends StatefulWidget {
  const _StyleEditor({
    required this.catalog,
    required this.screen,
    required this.schemas,
    required this.labels,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final Map<String, List<String>> schemas;
  final Map<String, List<String>> labels;
  @override
  State<_StyleEditor> createState() => _StyleEditorState();
}

class _StyleEditorState extends State<_StyleEditor> {
  late final Json original = Map<String, dynamic>.from(
    widget.catalog.screens
            .where(
              (s) =>
                  s['id'] == (widget.screen['query_id'] ?? widget.screen['id']),
            )
            .firstOrNull ??
        widget.screen,
  );
  String loadedDraft = '';
  int loadVersion = 0;
  late String table = widget.schemas.keys.last;
  late Json layouts = Map<String, dynamic>.from(
    widget.screen['report_layouts'] as Map? ?? {},
  );
  late List<Json> columns;
  final header = TextEditingController(), stripe = TextEditingController();
  double rowHeight = 36, fontSize = 13;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    loadVersion++;
    final layout = Map<String, dynamic>.from(layouts[table] as Map? ?? {});
    final fields = widget.schemas[table]!;
    final saved = objects(layout['columns']);
    columns = [
      for (final c in saved)
        if (fields.contains(c['key'])) Map.of(c),
      for (final f in fields)
        if (!saved.any((c) => c['key'] == f))
          {
            'key': f,
            'label': widget.labels[table]?[fields.indexOf(f)] ?? f,
            'visible': true,
          },
    ];
    header.text = '${layout['header_color'] ?? '#EFF4F8'}';
    stripe.text = '${layout['stripe_color'] ?? '#F7FAFC'}';
    rowHeight = (layout['row_height'] as num? ?? 36).toDouble();
    fontSize = (layout['font_size'] as num? ?? 13).toDouble();
    loadedDraft = jsonEncode(draft());
  }

  Json draft() => {
    'columns': columns,
    'header_color': header.text.trim(),
    'stripe_color': stripe.text.trim(),
    'row_height': rowHeight.round(),
    'font_size': fontSize.round(),
  };
  void capture() {
    final value = draft();
    if (jsonEncode(value) != loadedDraft) layouts[table] = value;
  }

  @override
  void dispose() {
    header.dispose();
    stripe.dispose();
    super.dispose();
  }

  Future<void> save() async {
    capture();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = await widget.catalog.api.request(
        'POST',
        '/api/v1/external/screens',
        body: {...original, 'report_layouts': layouts},
      );
      await widget.catalog.load();
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('报表样式'),
    content: SizedBox(
      width: 820,
      height: 540,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.schemas.length > 1)
            DropdownButtonFormField<String>(
              initialValue: table,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '表格'),
              items: [
                for (final s in widget.schemas.entries)
                  DropdownMenuItem(
                    value: s.key,
                    child: Text(
                      s.value.take(4).join(' / '),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      capture();
                      table = v!;
                      load();
                    }),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 155,
                child: TextField(
                  controller: header,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '表头颜色 #RRGGBB'),
                ),
              ),
              SizedBox(
                width: 155,
                child: TextField(
                  controller: stripe,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '隔行颜色 #RRGGBB'),
                ),
              ),
              SizedBox(
                width: 170,
                child: Column(
                  children: [
                    Text('行高 ${rowHeight.round()}'),
                    Slider(
                      min: 28,
                      max: 64,
                      divisions: 36,
                      value: rowHeight,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => rowHeight = v),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 150,
                child: Column(
                  children: [
                    Text('字号 ${fontSize.round()}'),
                    Slider(
                      min: 10,
                      max: 20,
                      divisions: 10,
                      value: fontSize,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => fontSize = v),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '按实际返回字段设置列；拖动调整顺序。小数位只改变显示，导出保留原数值。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: columns.length,
              buildDefaultDragHandles: false,
              onReorder: busy
                  ? (_, _) {}
                  : (a, b) => setState(() {
                      if (b > a) b--;
                      columns.insert(b, columns.removeAt(a));
                    }),
              itemBuilder: (context, i) {
                final c = columns[i];
                return Container(
                  key: ValueKey('$loadVersion-${c['key']}'),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 6,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xffe4e9ed)),
                    ),
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_indicator, size: 18),
                      ),
                      Checkbox(
                        value: c['visible'] != false,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => c['visible'] = v),
                      ),
                      SizedBox(
                        width: 160,
                        child: TextFormField(
                          key: ValueKey('${table}_${c['key']}_label'),
                          initialValue: '${c['label']}',
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: '列名',
                            helperText: '${c['key']}',
                            helperMaxLines: 1,
                          ),
                          onChanged: (v) => c['label'] = v,
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: TextFormField(
                          key: ValueKey('${table}_${c['key']}_width'),
                          initialValue: '${c['width'] ?? ''}',
                          enabled: !busy,
                          decoration: const InputDecoration(labelText: '宽度'),
                          keyboardType: TextInputType.number,
                          onChanged: (v) => c['width'] = int.tryParse(v) ?? 0,
                        ),
                      ),
                      SizedBox(
                        width: 100,
                        child: DropdownButtonFormField<String>(
                          initialValue: '${c['align'] ?? ''}',
                          decoration: const InputDecoration(labelText: '对齐'),
                          items: [
                            for (final a in {
                              '': '默认',
                              'left': '左',
                              'center': '中',
                              'right': '右',
                            }.entries)
                              DropdownMenuItem(
                                value: a.key,
                                child: Text(a.value),
                              ),
                          ],
                          onChanged: busy ? null : (v) => c['align'] = v,
                        ),
                      ),
                      SizedBox(
                        width: 105,
                        child: DropdownButtonFormField<int>(
                          initialValue: c['decimals'] as int? ?? -1,
                          decoration: const InputDecoration(labelText: '小数位'),
                          items: [
                            const DropdownMenuItem(
                              value: -1,
                              child: Text('原样'),
                            ),
                            for (var n = 0; n <= 6; n++)
                              DropdownMenuItem(value: n, child: Text('$n')),
                          ],
                          onChanged: busy
                              ? null
                              : (v) {
                                  if (v == -1) {
                                    c.remove('decimals');
                                  } else {
                                    c['decimals'] = v;
                                  }
                                },
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: TextFormField(
                          key: ValueKey('${table}_${c['key']}_group'),
                          initialValue: '${c['group'] ?? ''}',
                          enabled: !busy,
                          decoration: const InputDecoration(labelText: '合并表头组'),
                          onChanged: (v) => c['group'] = v,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy
            ? null
            : () => setState(() {
                layouts.remove(table);
                load();
              }),
        child: const Text('恢复当前表默认'),
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? '保存中…' : '保存样式'),
      ),
    ],
  );
}
