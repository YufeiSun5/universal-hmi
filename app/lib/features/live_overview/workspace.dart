import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../process/model.dart';
import '../process/gis_bindings.dart';
import '../process/runtime_chrome.dart';

const overviewPath = '/api/v1/live-overview';

List<Json> overviewTemplateColumns() {
  final groups = <String, List<String>>{
    '一次网热量与流量': ['瞬时热量', '累计热量', '瞬时流量', '累计流量'],
    '一次网温度与压力': ['供水温度', '回水温度', '供水压力', '回水压力', '调节阀反馈'],
    '二次网': ['供水温度', '回水温度', '供水压力', '回水压力', '瞬时流量'],
    '补水与水箱': ['水箱液位', '补水流量', '累计补水', '补水泵频率'],
    '循环泵': ['循环泵1电流', '循环泵1频率', '循环泵2电流', '循环泵2频率'],
    '电能': ['累计电量'],
  };
  return [
    for (final g in groups.entries)
      for (final name in g.value)
        {'id': screenIdentity(), 'group': g.key, 'name': name, 'decimals': 2},
  ];
}

class LiveOverview extends StatefulWidget {
  const LiveOverview({
    super.key,
    required this.api,
    required this.definitions,
    required this.live,
    required this.online,
    this.canEdit = false,
    this.stations = const [],
    this.onSubscriptionChanged,
  });
  final PlatformApi api;
  final Map<String, Json> definitions, live;
  final bool online, canEdit;
  final List<String> stations;
  final ValueChanged<Set<String>>? onSubscriptionChanged;
  @override
  State<LiveOverview> createState() => _LiveOverviewState();
}

class _LiveOverviewState extends State<LiveOverview> {
  Json? config;
  String? error;
  bool loading = true, tableOnPhone = false;
  String search = '', group = '', selectedRow = '';
  Set<String> subscribed = {};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final c = await widget.api.request('GET', overviewPath);
      if (mounted) {
        setState(() {
          config = c;
          if (!objects(
            c['columns'],
          ).any((column) => column['group'] == group)) {
            group = '';
          }
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
          config = null;
        });
      }
    }
  }

  Future<void> edit() async {
    final result = await showDialog<Json>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OverviewEditor(
        api: widget.api,
        config: config!,
        definitions: widget.definitions,
        stations: widget.stations,
      ),
    );
    if (mounted && result != null) {
      setState(() {
        config = result;
        group = '';
      });
    }
  }

  void subscribe(List<Json> rows, List<Json> columns) {
    final ids = <String>{
      for (final r in rows)
        for (final c in columns)
          if ((r['bindings'] as Map?)?[c['id']] case final String id)
            if (widget.definitions.containsKey(id)) id,
    };
    if (ids.length == subscribed.length && ids.containsAll(subscribed)) return;
    subscribed = ids;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSubscriptionChanged?.call(ids);
    });
  }

  ProcessValue value(Json row, Json col) => processValue(
    ScreenElement({
      'kind': 'value',
      'point_id': (row['bindings'] as Map?)?[col['id']] ?? '',
      'decimals': col['decimals'],
      'show_unit': true,
    }),
    ScreenDocument(id: 'overview', name: '数据总览', station: ''),
    widget.definitions,
    widget.live,
    widget.online,
  );
  Widget reading(Json row, Json col) {
    final v = value(row, col);
    return Tooltip(
      message: v.tooltip,
      child: Text(
        v.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: v.good ? FontWeight.w600 : FontWeight.normal,
          color: v.good ? ProcessStyle.ink : ProcessStyle.muted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final phone = box.maxWidth < 640;
      final cols = objects(config?['columns']);
      final rows = objects(config?['rows'])
          .where(
            (r) => '${r['area']} ${r['name']} ${r['station']}'
                .toLowerCase()
                .contains(search.toLowerCase()),
          )
          .toList();
      final groups = cols.map((c) => c['group'] as String).toSet().toList();
      final visibleCols = cols
          .where((c) => group.isEmpty || c['group'] == group)
          .toList();
      final selected =
          rows.where((r) => r['id'] == selectedRow).firstOrNull ??
          rows.firstOrNull;
      subscribe(phone && !tableOnPhone ? [?selected] : rows, visibleCols);
      return ColoredBox(
        color: RuntimeStyle.paper,
        child: Padding(
          padding: EdgeInsets.all(phone ? 10 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: phone ? math.max(130, box.maxWidth - 132) : 240,
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: '搜索区域、站点',
                      ),
                      onChanged: (v) => setState(() => search = v),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新总览配置',
                    onPressed: loading ? null : load,
                    icon: const Icon(Icons.refresh),
                  ),
                  if (phone)
                    IconButton(
                      tooltip: tableOnPhone ? '切换站点视图' : '切换完整表格',
                      onPressed: () =>
                          setState(() => tableOnPhone = !tableOnPhone),
                      icon: Icon(
                        tableOnPhone
                            ? Icons.view_agenda_outlined
                            : Icons.table_chart_outlined,
                      ),
                    ),
                  if (widget.canEdit)
                    FilledButton.tonalIcon(
                      onPressed: config == null ? null : edit,
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('配置总览'),
                    ),
                  if (!phone)
                    Text(
                      '${rows.length} 个站点行 · ${visibleCols.length} 项指标',
                      style: const TextStyle(color: ProcessStyle.muted),
                    ),
                ],
              ),
              if (groups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final g in ['', ...groups])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(g.isEmpty ? '全部指标' : g),
                              selected: group == g,
                              onSelected: (_) => setState(() => group = g),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (loading) const LinearProgressIndicator(minHeight: 2),
              if (error != null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('总览暂时无法读取\n$error', textAlign: TextAlign.center),
                        TextButton(onPressed: load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              else if (!loading && (cols.isEmpty || rows.isEmpty))
                Expanded(
                  child: Center(
                    child: Text(
                      cols.isEmpty
                          ? (widget.canEdit
                                ? '点击“配置总览”添加指标与站点，并绑定已有变量'
                                : '数据总览尚未配置')
                          : '没有匹配或已授权的站点行',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else if (config != null && rows.isNotEmpty && cols.isNotEmpty)
                Expanded(
                  child: phone && !tableOnPhone
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'row-${selected?['id']}-${rows.length}',
                              ),
                              initialValue: selected?['id'] as String?,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '站点',
                                isDense: true,
                              ),
                              items: [
                                for (final r in rows)
                                  DropdownMenuItem(
                                    value: r['id'] as String,
                                    child: Text(
                                      '${r['area']} / ${r['name']}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (id) =>
                                  setState(() => selectedRow = id ?? ''),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView(
                                children: [
                                  for (final g
                                      in visibleCols
                                          .map((c) => c['group'] as String)
                                          .toSet()) ...[
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        g,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: ProcessStyle.ink,
                                        ),
                                      ),
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (final c in visibleCols.where(
                                          (c) => c['group'] == g,
                                        ))
                                          Container(
                                            width: (box.maxWidth - 28) / 2,
                                            constraints: const BoxConstraints(
                                              minHeight: 76,
                                            ),
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              border: Border.all(
                                                color: ProcessStyle.line,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  c['name'] as String,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: ProcessStyle.muted,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                reading(selected!, c),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        )
                      : OverviewTable(
                          columns: visibleCols,
                          rows: rows,
                          reading: reading,
                        ),
                ),
              if (config != null && rows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.online ? '实时数据 · 单位随绑定变量显示' : '连接中断 · 实时数据暂不可用',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.online
                          ? ProcessStyle.muted
                          : Colors.deepOrange,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// One vertical list keeps row labels pinned; header and body share one horizontal offset.
class OverviewTable extends StatefulWidget {
  const OverviewTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.reading,
  });
  final List<Json> columns, rows;
  final Widget Function(Json, Json) reading;
  @override
  State<OverviewTable> createState() => _OverviewTableState();
}

class _OverviewTableState extends State<OverviewTable> {
  final horizontal = ScrollController();
  @override
  void dispose() {
    horizontal.dispose();
    super.dispose();
  }

  Widget cell(Widget child, {double width = 140, Color? color}) => Container(
    width: width,
    height: 62,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: color,
      border: const Border(
        right: BorderSide(color: ProcessStyle.line),
        bottom: BorderSide(color: ProcessStyle.line),
      ),
    ),
    child: child,
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final labelWidth = box.maxWidth < 640 ? 120.0 : 180.0;
      final width = widget.columns.length * 140.0;
      final groups = <(String, int)>[];
      for (final c in widget.columns) {
        final name = c['group'] as String;
        if (groups.isNotEmpty && groups.last.$1 == name) {
          final previous = groups.removeLast();
          groups.add((name, previous.$2 + 1));
        } else {
          groups.add((name, 1));
        }
      }
      return DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: ProcessStyle.line)),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  height: 82,
                  child: const Center(
                    child: Text(
                      '区域 / 站点',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: horizontal,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: width,
                        height: 82,
                        child: Column(
                          children: [
                            SizedBox(
                              height: 28,
                              child: Row(
                                children: [
                                  for (final g in groups)
                                    Container(
                                      width: g.$2 * 140.0,
                                      alignment: Alignment.center,
                                      decoration: const BoxDecoration(
                                        color: Color(0xffdce3e8),
                                        border: Border(
                                          right: BorderSide(
                                            color: ProcessStyle.line,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        g.$1,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: 44,
                              child: Row(
                                children: [
                                  for (final c in widget.columns)
                                    SizedBox(
                                      width: 140,
                                      child: Center(
                                        child: Text(
                                          c['name'] as String,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
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
              ],
            ),
            Expanded(
              child: GestureDetector(
                onHorizontalDragUpdate: (d) {
                  if (horizontal.hasClients) {
                    horizontal.jumpTo(
                      (horizontal.offset - d.delta.dx).clamp(
                        0,
                        horizontal.position.maxScrollExtent,
                      ),
                    );
                  }
                },
                child: AnimatedBuilder(
                  animation: horizontal,
                  builder: (context, _) => ListView.builder(
                    itemExtent: 62,
                    itemCount: widget.rows.length,
                    itemBuilder: (context, i) {
                      final r = widget.rows[i];
                      return ColoredBox(
                        color: i.isEven
                            ? Colors.white
                            : const Color(0xfff1f3f5),
                        child: Row(
                          children: [
                            cell(
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r['name'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    r['area'] as String? ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: ProcessStyle.muted,
                                    ),
                                  ),
                                ],
                              ),
                              width: labelWidth,
                              color: const Color(0xffe8ecef),
                            ),
                            Expanded(
                              child: ClipRect(
                                child: SizedBox(
                                  height: 62,
                                  child: OverflowBox(
                                    alignment: Alignment.centerLeft,
                                    minWidth: width,
                                    maxWidth: width,
                                    child: Transform.translate(
                                      offset: Offset(
                                        horizontal.hasClients
                                            ? -horizontal.offset
                                            : 0,
                                        0,
                                      ),
                                      child: Row(
                                        children: [
                                          for (final c in widget.columns)
                                            cell(widget.reading(r, c)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class AlarmPlaceholder extends StatelessWidget {
  const AlarmPlaceholder({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.notifications_none_rounded,
            size: 48,
            color: ProcessStyle.muted,
          ),
          const SizedBox(height: 16),
          const Text(
            '报警记录待接入',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            '将读取现场已有报警数据库，与历史查询使用同一外部连接。\n当前尚未接入，不能据此判断现场是否存在报警。',
            textAlign: TextAlign.center,
            style: TextStyle(color: ProcessStyle.muted, height: 1.7),
          ),
        ],
      ),
    ),
  );
}

class OverviewEditor extends StatefulWidget {
  const OverviewEditor({
    super.key,
    required this.api,
    required this.config,
    required this.definitions,
    required this.stations,
  });
  final PlatformApi api;
  final Json config;
  final Map<String, Json> definitions;
  final List<String> stations;
  @override
  State<OverviewEditor> createState() => _OverviewEditorState();
}

class _OverviewEditorState extends State<OverviewEditor> {
  late Json draft = jsonDecode(jsonEncode(widget.config)) as Json;
  late List<Json> columns = objects(draft['columns']);
  late List<Json> rows = objects(draft['rows']);
  int tab = 0;
  String rowID = '';
  bool saving = false;
  String? error;
  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final c = await widget.api.request(
        'PUT',
        overviewPath,
        body: {...draft, 'columns': columns, 'rows': rows},
      );
      if (mounted) Navigator.pop(context, c);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          saving = false;
        });
      }
    }
  }

  Widget field(Json item, String key, String label, {double width = 160}) =>
      SizedBox(
        width: width,
        child: TextFormField(
          key: ValueKey('${item['id']}-$key'),
          initialValue: item[key]?.toString() ?? '',
          maxLength: 80,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            counterText: '',
          ),
          onChanged: (v) => item[key] = v,
        ),
      );
  List<Widget> order(List<Json> items, int index) => [
    IconButton(
      tooltip: '上移',
      onPressed: index == 0
          ? null
          : () => setState(() {
              final item = items.removeAt(index);
              items.insert(index - 1, item);
            }),
      icon: const Icon(Icons.arrow_upward, size: 18),
    ),
    IconButton(
      tooltip: '下移',
      onPressed: index == items.length - 1
          ? null
          : () => setState(() {
              final item = items.removeAt(index);
              items.insert(index + 1, item);
            }),
      icon: const Icon(Icons.arrow_downward, size: 18),
    ),
    IconButton(
      tooltip: '移除',
      onPressed: () => setState(() {
        final item = items.removeAt(index);
        if (items == columns) {
          for (final r in rows) {
            (r['bindings'] as Map).remove(item['id']);
          }
        }
      }),
      icon: const Icon(Icons.close, size: 18),
    ),
  ];
  Future<void> bind(Json row, Json col) async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) =>
          GisPointPicker(definitions: widget.definitions, title: '选择总览变量'),
    );
    if (id != null && mounted) {
      setState(() {
        (row['bindings'] as Map)[col['id']] = id;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        rows.where((r) => r['id'] == rowID).firstOrNull ?? rows.firstOrNull;
    return AlertDialog(
      title: const Text('数据总览配置'),
      content: SizedBox(
        width: 960,
        height: 620,
        child: AbsorbPointer(
          absorbing: saving,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '编辑展示结构与已有变量绑定；保存不会修改实时值或启动采集。',
                style: TextStyle(fontSize: 12, color: ProcessStyle.muted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in {0: '指标列', 1: '站点行', 2: '变量绑定'}.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: tab == entry.key,
                      onSelected: (_) => setState(() => tab = entry.key),
                    ),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (tab == 0)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: columns.length >= 64
                          ? null
                          : () => setState(
                              () => columns.add({
                                'id': screenIdentity(),
                                'group': '新分组',
                                'name': '新指标',
                                'decimals': 2,
                              }),
                            ),
                      icon: const Icon(Icons.add),
                      label: const Text('添加指标'),
                    ),
                    TextButton(
                      onPressed: columns.isNotEmpty
                          ? null
                          : () => setState(
                              () => columns = overviewTemplateColumns(),
                            ),
                      child: const Text('使用供热报表结构（空绑定）'),
                    ),
                  ],
                ),
              if (tab == 1)
                TextButton.icon(
                  onPressed:
                      rows.length >= 256 ||
                          widget.stations.where((s) => s.isNotEmpty).isEmpty
                      ? null
                      : () => setState(() {
                          final station = widget.stations.firstWhere(
                            (s) => s.isNotEmpty,
                          );
                          rows.add({
                            'id': screenIdentity(),
                            'area': '',
                            'name': station,
                            'station': station,
                            'bindings': <String, String>{},
                          });
                        }),
                  icon: const Icon(Icons.add),
                  label: const Text('添加站点行'),
                ),
              if (tab == 2 && active != null)
                DropdownButtonFormField<String>(
                  key: ValueKey(active['id']),
                  initialValue: active['id'] as String,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '选择站点行'),
                  items: [
                    for (final r in rows)
                      DropdownMenuItem(
                        value: r['id'] as String,
                        child: Text(r['name'] as String),
                      ),
                  ],
                  onChanged: (v) => setState(() => rowID = v ?? ''),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: tab == 0
                    ? ListView.builder(
                        itemCount: columns.length,
                        itemBuilder: (_, i) {
                          final c = columns[i];
                          return Padding(
                            key: ValueKey(c['id']),
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                field(c, 'group', '分组', width: 180),
                                field(c, 'name', '指标名称', width: 200),
                                SizedBox(
                                  width: 100,
                                  child: DropdownButtonFormField<int>(
                                    initialValue: c['decimals'] as int,
                                    decoration: const InputDecoration(
                                      labelText: '小数位',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (var n = 0; n <= 6; n++)
                                        DropdownMenuItem(
                                          value: n,
                                          child: Text('$n'),
                                        ),
                                    ],
                                    onChanged: (v) => c['decimals'] = v ?? 2,
                                  ),
                                ),
                                ...order(columns, i),
                              ],
                            ),
                          );
                        },
                      )
                    : tab == 1
                    ? ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final r = rows[i];
                          final stations = {
                            ...widget.stations.where((s) => s.isNotEmpty),
                            r['station'] as String,
                          }.toList();
                          return Padding(
                            key: ValueKey(r['id']),
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                field(r, 'area', '区域'),
                                field(r, 'name', '显示名称'),
                                SizedBox(
                                  width: 200,
                                  child: DropdownButtonFormField<String>(
                                    initialValue: r['station'] as String,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                      labelText: '授权归属站点',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (final s in stations)
                                        DropdownMenuItem(
                                          value: s,
                                          child: Text(
                                            s,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                    onChanged: (v) =>
                                        r['station'] = v ?? r['station'],
                                  ),
                                ),
                                ...order(rows, i),
                              ],
                            ),
                          );
                        },
                      )
                    : active == null
                    ? const Center(child: Text('请先添加站点行'))
                    : ListView.builder(
                        itemCount: columns.length,
                        itemBuilder: (_, i) {
                          final c = columns[i],
                              id = (active['bindings'] as Map)[c['id']];
                          final p = widget.definitions[id];
                          return ListTile(
                            title: Text('${c['group']} / ${c['name']}'),
                            subtitle: Text(
                              id == null
                                  ? '未绑定'
                                  : p == null
                                  ? '变量已不可用，请重新绑定'
                                  : '${p['station']} / ${p['name']} · ${p['unit'] ?? ''}',
                            ),
                            onTap: () => bind(active, c),
                            trailing: id == null
                                ? const Icon(Icons.link)
                                : IconButton(
                                    tooltip: '清除绑定',
                                    onPressed: () => setState(
                                      () => (active['bindings'] as Map).remove(
                                        c['id'],
                                      ),
                                    ),
                                    icon: const Icon(Icons.link_off),
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存总览'),
        ),
      ],
    );
  }
}
