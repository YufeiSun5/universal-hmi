import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import '../../shared/report_style_transfer.dart';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/report_style.dart';
import '../../shared/report_time.dart';
import '../../shared/report_time_editor.dart';
import '../../shared/form_control_theme.dart';
import '../../shared/column_order_toolbar.dart';
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
            groups: styles.groups,
            groupKeys: styles.groupKeys,
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
    required this.groups,
    required this.groupKeys,
    required this.initialLayouts,
    required this.legacyLayoutKeys,
    this.sourceScreen,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final Json? sourceScreen;
  final Map<String, List<String>> schemas;
  final Map<String, List<String>> labels;
  final Map<String, List<String>> descriptions, groups, groupKeys;
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
  String? selectedColumn;
  final columnScroll = ScrollController();
  final columnKeys = <String, GlobalKey>{};
  final header = TextEditingController(), stripe = TextEditingController();
  double rowHeight = 36, fontSize = 13;
  bool busy = false;
  String? error;
  String? message;
  int section = 0;
  Json groupLabels = {};
  final horizontalScroll = ScrollController();
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    loadVersion++;
    columnKeys.clear();
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
    groupLabels = Map<String, dynamic>.from(
      layout['group_labels'] as Map? ?? {},
    );
    header.text = '${layout['header_color'] ?? '#EFF4F8'}';
    selectedColumn = columns.firstOrNull?['key'] as String?;
    stripe.text = '${layout['stripe_color'] ?? '#F7FAFC'}';
    rowHeight = (layout['row_height'] as num? ?? 36).toDouble();
    fontSize = (layout['font_size'] as num? ?? 13).toDouble();
    loadedDraft = jsonEncode(draft());
  }

  Json draft() => {
    'group_labels': groupLabels,
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

  void moveSelected(int delta) {
    final index = columns.indexWhere((c) => c['key'] == selectedColumn);
    if (busy ||
        index < 0 ||
        index + delta < 0 ||
        index + delta >= columns.length) {
      return;
    }
    final selectedContext = columnKeys[selectedColumn]?.currentContext;
    final box = selectedContext?.mounted == true
        ? selectedContext!.findRenderObject()
        : null;
    final nextOffset =
        columnScroll.hasClients && box is RenderBox && box.hasSize
        ? columnScroll.offset + delta * box.size.height
        : null;
    setState(() => columns.insert(index + delta, columns.removeAt(index)));
    if (nextOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && columnScroll.hasClients) {
          columnScroll.jumpTo(
            nextOffset.clamp(0, columnScroll.position.maxScrollExtent),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    header.dispose();
    horizontalScroll.dispose();
    columnScroll.dispose();
    stripe.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!columns.any((c) => c['visible'] != false)) {
      setState(() => error = '当前结果至少保留一列');
      return;
    }
    try {
      validateReportStyle({
        ...draft(),
        'columns': columns,
      }, widget.schemas[table]!);
    } catch (e) {
      setState(() => error = '$e');
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

  List<ReportHeaderGroup> get currentGroups {
    final result = <String, ReportHeaderGroup>{};
    for (final c in columns) {
      final i = widget.schemas[table]!.indexOf(c['key']);
      final g = reportHeaderGroup(
        c,
        {'group_labels': groupLabels},
        sourceLabel: widget.groups[table]?[i] ?? '',
        sourceKey: widget.groupKeys[table]?[i],
      );
      if (g.key.isNotEmpty) result[g.key] = g;
    }
    return result.values.toList();
  }

  Future<void> transfer(bool importing) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      if (importing) {
        final file = await pickProcessFile(
          image: false,
          jsonLabel: '报表样式 JSON',
        );
        if (file == null || !mounted) return;
        final next = decodeReportStyle(
          utf8.decode(file.bytes),
          table: table,
          kind: '${widget.screen['kind']}',
          fields: widget.schemas[table]!,
        );
        // Preserve settings for fields outside the currently queried stations.
        next['columns'] = [
          ...objects(next['columns']),
          for (final c in objects(draft()['columns']))
            if (!widget.schemas[table]!.contains(c['key'])) c,
        ];
        setState(() {
          layouts[table] = next;
          load();
          message = '已导入 ${file.name}，保存样式后生效';
        });
      } else {
        final layout = validateReportStyle({
          ...draft(),
          'columns': columns,
        }, widget.schemas[table]!);
        final data = {
          'format': reportStyleFormat,
          'version': 1,
          'screen_kind': widget.screen['kind'],
          'table_key': table,
          'instructions':
              '修改 layout；columns 数组顺序决定列顺序，visible 控制显隐。group_labels 按稳定标识修改上层标题。不要修改 key；删除列请用 visible:false。导入只载入草稿，保存后生效。',
          'fields': [
            for (var i = 0; i < widget.schemas[table]!.length; i++)
              {
                'key': widget.schemas[table]![i],
                'source_label': widget.labels[table]?[i],
                'source_group': widget.groups[table]?[i],
                'source_group_key': widget.groupKeys[table]?[i],
              },
          ],
          'header_groups': [
            for (final g in currentGroups)
              {'key': g.key, 'source_label': g.sourceLabel},
          ],
          'layout': {
            ...layout,
            'group_labels': {
              ...groupLabels,
              for (final g in currentGroups) g.key: g.label,
            },
          },
        };
        if (await saveFile(
              Uint8List.fromList(
                utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
              ),
              '报表样式-$table.json',
            ) &&
            mounted) {
          setState(() => message = '已导出当前表格样式');
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get compactTouch => MediaQuery.sizeOf(context).width < 600;
  double get editorRowHeight => compactTouch ? 53 : 44;

  InputDecoration cellDecoration(String hint) => InputDecoration(
    hintText: hint,
    constraints: BoxConstraints(
      minHeight: compactTouch ? 44 : 34,
      maxHeight: compactTouch ? 44 : 34,
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
  );

  Widget columnRow(int i) {
    final c = columns[i];
    final description =
        widget.descriptions[table]?[widget.schemas[table]!.indexOf(c['key'])] ??
        '${c['key']}';
    Widget cell(double width, Widget child) => SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: SizedBox(height: compactTouch ? 44 : 34, child: child),
        ),
      ),
    );
    return Container(
      key: ValueKey('$loadVersion-${c['key']}'),
      height: editorRowHeight,
      decoration: BoxDecoration(
        color: selectedColumn == c['key'] ? const Color(0xffe3edf5) : null,
        border: const Border(bottom: BorderSide(color: Color(0xffe4e9ed))),
      ),
      child: Row(
        key: columnKeys.putIfAbsent(c['key'] as String, () => GlobalKey()),
        children: [
          cell(
            52,
            IconButton(
              key: ValueKey('select-column-${c['key']}'),
              tooltip: '选择此列调整顺序',
              onPressed: busy
                  ? null
                  : () => setState(() => selectedColumn = c['key'] as String),
              icon: Icon(
                selectedColumn == c['key']
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
            ),
          ),
          cell(
            52,
            Checkbox(
              value: c['visible'] != false,
              onChanged: busy ? null : (v) => setState(() => c['visible'] = v),
            ),
          ),
          cell(
            210,
            Tooltip(
              message: description,
              child: TextFormField(
                key: ValueKey('${table}_${c['key']}_label'),
                initialValue: '${c['label']}',
                enabled: !busy,
                decoration: cellDecoration('列名'),
                onChanged: (v) => c['label'] = v,
              ),
            ),
          ),
          cell(
            210,
            Tooltip(
              message: description,
              child: Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          cell(
            72,
            TextFormField(
              key: ValueKey('${table}_${c['key']}_width'),
              initialValue: '${c['width'] ?? ''}',
              enabled: !busy,
              decoration: cellDecoration('默认'),
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  c['width'] = v.isEmpty ? 0 : int.tryParse(v) ?? -1,
            ),
          ),
          cell(
            100,
            DropdownButtonFormField<String>(
              initialValue: '${c['align'] ?? ''}',
              isExpanded: true,
              decoration: cellDecoration('对齐'),
              items: [
                for (final a in {
                  '': '默认',
                  'left': '左',
                  'center': '中',
                  'right': '右',
                }.entries)
                  DropdownMenuItem(value: a.key, child: Text(a.value)),
              ],
              onChanged: busy ? null : (v) => c['align'] = v,
            ),
          ),
          cell(
            100,
            DropdownButtonFormField<int>(
              initialValue: c['decimals'] as int? ?? -1,
              isExpanded: true,
              decoration: cellDecoration('小数位'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('默认')),
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
          cell(
            150,
            TextFormField(
              key: ValueKey('${table}_${c['key']}_group'),
              initialValue: '${c['group'] ?? ''}',
              enabled: !busy,
              decoration: cellDecoration('沿用原分组'),
              onChanged: (v) => c['group'] = v,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> editTimeZone() async {
    final column = columns.where((c) => c['key'] == selectedColumn).firstOrNull;
    if (column == null) return;
    final change = await showDialog<Json>(
      context: context,
      builder: (_) => ReportTimeEditor(
        label: '${column['label']}',
        value: column['time_zone'] == null
            ? null
            : Map<String, dynamic>.from(column['time_zone']),
      ),
    );
    if (!mounted || change == null) return;
    setState(() {
      column.remove('time_zone');
      column.addAll(change);
    });
  }

  Widget columnList() => Column(
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final order = ColumnOrderToolbar(
            label:
                '${columns.where((c) => c['key'] == selectedColumn).firstOrNull?['label'] ?? ''}',
            index: columns.indexWhere((c) => c['key'] == selectedColumn),
            length: columns.length,
            busy: busy,
            onMove: moveSelected,
          );
          final zone =
              columns
                      .where((c) => c['key'] == selectedColumn)
                      .firstOrNull?['time_zone']
                  as Map?;
          final hint = zone == null
              ? '时间列时区转换（未启用）'
              : '时间列时区转换：${reportTimeZoneLabel(zone['source_offset_minutes'] as int)} → ${reportTimeZoneLabel(zone['target_offset_minutes'] as int)}';
          final action = busy || selectedColumn == null ? null : editTimeZone;
          final time = constraints.maxWidth < 600
              ? IconButton(
                  key: const ValueKey('column-time-zone'),
                  tooltip: hint,
                  onPressed: action,
                  icon: Icon(
                    zone == null ? Icons.schedule : Icons.update,
                    size: 20,
                  ),
                )
              : Tooltip(
                  message: hint,
                  child: TextButton.icon(
                    key: const ValueKey('column-time-zone'),
                    onPressed: action,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(zone == null ? '时间列时区转换' : '时区转换（已启用）'),
                  ),
                );
          return Row(
            children: [
              Expanded(child: order),
              const SizedBox(width: 8),
              time,
            ],
          );
        },
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) => Scrollbar(
            controller: horizontalScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: horizontalScroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: constraints.maxWidth < 1046
                    ? 1046
                    : constraints.maxWidth,
                height: constraints.maxHeight,
                child: Column(
                  children: [
                    Container(
                      height: 28,
                      color: const Color(0xffeff4f8),
                      child: const Row(
                        children: [
                          SizedBox(width: 52),
                          SizedBox(width: 52, child: Text('显示')),
                          SizedBox(width: 210, child: Text('下层标题 / 列名')),
                          SizedBox(width: 210, child: Text('原字段 / 分组')),
                          SizedBox(width: 72, child: Text('宽度')),
                          SizedBox(width: 100, child: Text('对齐')),
                          SizedBox(width: 100, child: Text('小数位')),
                          SizedBox(width: 150, child: Text('自定义合并组')),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        key: const ValueKey('result-column-list'),
                        controller: columnScroll,
                        itemExtent: editorRowHeight,
                        padding: const EdgeInsets.only(bottom: 14),
                        findChildIndexCallback: (key) {
                          final index = columns.indexWhere(
                            (c) => key == ValueKey('$loadVersion-${c['key']}'),
                          );
                          return index < 0 ? null : index;
                        },
                        itemCount: columns.length,
                        itemBuilder: (context, i) => columnRow(i),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget groupsEditor() => ListView(
    children: [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('修改上层标题显示名称；留空恢复原名称，不改变字段绑定。'),
      ),
      if (currentGroups.isEmpty) const Text('当前表格没有上层标题。可在列设置中填写自定义合并组。'),
      for (final g in currentGroups)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Tooltip(message: g.key, child: Text(g.sourceLabel)),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: ValueKey('$loadVersion-group-label-${g.key}'),
                  initialValue: '${groupLabels[g.key] ?? ''}',
                  enabled: !busy,
                  decoration: cellDecoration(g.sourceLabel),
                  onChanged: (v) {
                    if (v.trim().isEmpty) {
                      groupLabels.remove(g.key);
                    } else {
                      groupLabels[g.key] = v.trim();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget appearanceEditor() => ListView(
    children: [
      const SizedBox(height: 12),
      TextField(
        controller: header,
        enabled: !busy,
        decoration: const InputDecoration(labelText: '表头颜色 #RRGGBB'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: stripe,
        enabled: !busy,
        decoration: const InputDecoration(labelText: '隔行颜色 #RRGGBB'),
      ),
      const SizedBox(height: 16),
      Text('行高 ${rowHeight.round()}'),
      Slider(
        min: 28,
        max: 64,
        divisions: 36,
        value: rowHeight,
        onChanged: busy ? null : (v) => setState(() => rowHeight = v),
      ),
      Text('字号 ${fontSize.round()}'),
      Slider(
        min: 10,
        max: 20,
        divisions: 10,
        value: fontSize,
        onChanged: busy ? null : (v) => setState(() => fontSize = v),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: SizedBox(
      width: 1180,
      height: MediaQuery.sizeOf(context).height - 24,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '报表样式',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : () => transfer(true),
                  child: const Text('导入 JSON'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : () => transfer(false),
                  child: const Text('导出 JSON'),
                ),
              ],
            ),
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
            Text(
              '当前结果共 ${columns.length} 列 · 显示 ${columns.where((c) => c['visible'] != false).length} 列',
              style: const TextStyle(fontSize: 12),
            ),
            Row(
              children: [
                for (final e in ['列设置', '上层标题', '外观'].asMap().entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: section == e.key
                            ? const Color(0xffe3edf5)
                            : null,
                      ),
                      onPressed: busy
                          ? null
                          : () => setState(() => section = e.key),
                      child: Text(e.value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: section == 0
                  ? columnList()
                  : section == 1
                  ? groupsEditor()
                  : appearanceEditor(),
            ),
            if (error != null || message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  error ?? message!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: error != null
                        ? Theme.of(context).colorScheme.error
                        : null,
                    fontSize: 12,
                  ),
                ),
              ),
            const Divider(height: 8),
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              layouts.remove(table);
                              layouts.remove(widget.legacyLayoutKeys[table]);
                              load();
                            }),
                      child: const Text('恢复当前表默认'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(busy ? '处理中…' : '保存样式'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
