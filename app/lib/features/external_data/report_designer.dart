import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/report_style.dart';
import '../../shared/form_control_theme.dart';
import 'catalog.dart';

class ReportStyleHost extends StatefulWidget {
  const ReportStyleHost({
    super.key,
    required this.screen,
    required this.child,
    this.api,
  });
  final Json screen;
  final Widget child;
  final PlatformApi? api;
  @override
  State<ReportStyleHost> createState() => _ReportStyleHostState();
}

class _ReportStyleHostState extends State<ReportStyleHost> {
  late final styles = ReportStyles(widget.screen);
  Timer? refreshTimer;
  bool refreshing = false;
  String? syncError;
  @override
  void initState() {
    super.initState();
    if (widget.api != null) {
      refreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => refresh(),
      );
    }
  }

  @override
  void didUpdateWidget(ReportStyleHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.screen['revision'] as int? ?? 0) >=
        (styles.screen['revision'] as int? ?? 0)) {
      styles.screen = widget.screen;
      styles.sourceScreen = null;
    }
  }

  Future<void> refresh() async {
    if (refreshing || widget.api == null) return;
    refreshing = true;
    try {
      final data = await widget.api!.request('GET', '/api/v1/external/screens');
      if (!mounted) return;
      final source = objects(data['items'])
          .where(
            (s) =>
                s['id'] == (widget.screen['query_id'] ?? widget.screen['id']),
          )
          .firstOrNull;
      if (source == null) throw StateError('画面已删除或无权访问');
      if ((source['revision'] as int? ?? 0) >
              (styles.screen['revision'] as int? ?? 0) ||
          syncError != null) {
        setState(() {
          if ((source['revision'] as int? ?? 0) >=
              (styles.screen['revision'] as int? ?? 0)) {
            styles.sourceScreen = source;
            styles.screen = {
              ...source,
              if (widget.screen['query_id'] != null) ...{
                'id': widget.screen['id'],
                'query_id': widget.screen['query_id'],
                'kind': widget.screen['kind'],
                'name': widget.screen['name'],
              },
            };
          }
          syncError = null;
        });
      }
    } catch (_) {
      if (mounted && syncError == null) {
        setState(() => syncError = '报表配置同步失败，点击重试');
      }
    } finally {
      refreshing = false;
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ReportStyleScope(
      styles: styles,
      child: Column(
        children: [
          if (syncError != null)
            TextButton(onPressed: refresh, child: Text(syncError!)),
          Expanded(child: widget.child),
        ],
      ),
    );
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
      final currentScreen = styles.screen;
      final schemas = Map<String, List<String>>.from(styles.schemas);
      final labels = Map<String, List<String>>.from(styles.labels);
      // A renamed SQL field can reject the query before a schema is registered.
      // Keep the saved layout reachable so it can be reset without recreating
      // the report or changing its authorization identity.
      final savedLayouts = currentScreen['report_layouts'];
      if (schemas.isEmpty &&
          screen['kind'] == 'custom' &&
          savedLayouts is Map) {
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
            screen: currentScreen,
            sourceScreen: styles.sourceScreen,
            schemas: schemas,
            labels: labels,
            descriptions: styles.descriptions,
            initialLayouts: {
              ...currentScreen['report_layouts'] as Map? ?? {},
              for (final entry in styles.currentLayouts.entries)
                if (entry.value.isNotEmpty) entry.key: entry.value,
            },
            legacyLayoutKeys: styles.legacyLayoutKeys,
          ),
        ),
      );
      if (saved != null) {
        onSaved?.call({
          ...saved,
          if (screen['query_id'] != null) ...{
            'id': screen['id'],
            'query_id': screen['query_id'],
            'kind': screen['kind'],
            'name': screen['name'],
          },
        });
      }
    },
  );
}

class _StyleEditor extends StatefulWidget {
  const _StyleEditor({
    required this.catalog,
    required this.screen,
    required this.schemas,
    required this.labels,
    required this.descriptions,
    required this.initialLayouts,
    required this.legacyLayoutKeys,
    this.sourceScreen,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final Json? sourceScreen;
  final Map<String, List<String>> schemas;
  final Map<String, List<String>> labels;
  final Map<String, List<String>> descriptions;
  final Map<String, dynamic> initialLayouts;
  final Map<String, String> legacyLayoutKeys;
  @override
  State<_StyleEditor> createState() => _StyleEditorState();
}

class _StyleEditorState extends State<_StyleEditor> {
  late final Json original = Map<String, dynamic>.from(
    widget.sourceScreen ??
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
  late Json layouts = Map<String, dynamic>.from(widget.initialLayouts);
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
    'columns': [
      ...columns,
      // Keep settings for other station fields of the same report.
      for (final c in objects((layouts[table] as Map?)?['columns']))
        if (!widget.schemas[table]!.contains(c['key'])) c,
    ],
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
    if (!columns.any((c) => c['visible'] != false)) {
      setState(() => error = '当前结果至少保留一列');
      return;
    }
    capture();
    for (final entry in widget.legacyLayoutKeys.entries) {
      if (entry.key != entry.value && layouts.containsKey(entry.key)) {
        layouts.remove(entry.value);
      }
    }
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
    actionsPadding: const EdgeInsets.all(16),
    buttonPadding: EdgeInsets.zero,
    content: SizedBox(
      width: 820,
      height: 540,
      child: SingleChildScrollView(
        child: SizedBox(
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
                      decoration: const InputDecoration(
                        labelText: '表头颜色 #RRGGBB',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 155,
                    child: TextField(
                      controller: stripe,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: '隔行颜色 #RRGGBB',
                      ),
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
                  '按实际返回字段设置列；用上下箭头调整顺序。小数位只改变显示，导出保留原数值。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '当前结果共 ${columns.length} 列 · 显示 ${columns.where((c) => c['visible'] != false).length} 列',
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('result-column-list'),
                  itemCount: columns.length,
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
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: ValueKey('move-up-${c['key']}'),
                                tooltip: '上移此列',
                                visualDensity: VisualDensity.compact,
                                onPressed: busy || i == 0
                                    ? null
                                    : () => setState(() {
                                        columns.insert(
                                          i - 1,
                                          columns.removeAt(i),
                                        );
                                      }),
                                icon: const Icon(Icons.arrow_upward, size: 16),
                              ),
                              IconButton(
                                key: ValueKey('move-down-${c['key']}'),
                                tooltip: '下移此列',
                                visualDensity: VisualDensity.compact,
                                onPressed: busy || i == columns.length - 1
                                    ? null
                                    : () => setState(() {
                                        columns.insert(
                                          i + 1,
                                          columns.removeAt(i),
                                        );
                                      }),
                                icon: const Icon(
                                  Icons.arrow_downward,
                                  size: 16,
                                ),
                              ),
                            ],
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
                                helperText:
                                    widget.descriptions[table]?[widget
                                        .schemas[table]!
                                        .indexOf(c['key'])] ??
                                    '${c['key']}',
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
                              decoration: const InputDecoration(
                                labelText: '宽度',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (v) =>
                                  c['width'] = int.tryParse(v) ?? 0,
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: DropdownButtonFormField<String>(
                              initialValue: '${c['align'] ?? ''}',
                              decoration: const InputDecoration(
                                labelText: '对齐',
                              ),
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
                              decoration: const InputDecoration(
                                labelText: '小数位',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: -1,
                                  child: Text('默认'),
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
                              decoration: const InputDecoration(
                                labelText: '合并表头组',
                              ),
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
      ),
    ),
    actions: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    layouts.remove(table);
                    layouts.remove(widget.legacyLayoutKeys[table]);
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
      ),
    ],
  );
}
