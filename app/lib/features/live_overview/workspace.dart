import '../../shared/query_toolbar.dart';
import '../../shared/table_csv.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../platform/process_files.dart';
import '../../platform/save.dart';
import 'transfer.dart';
import '../../shared/transfer_rows.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/theme.dart' show numericStyle;
import '../process/model.dart';
import '../process/gis_bindings.dart';
import '../process/runtime_chrome.dart';

const overviewPath = '/api/v1/live-overview';

// Display order follows the reference displayGroups, not transport order.
const overviewReferenceColumns = <Json>[
  {
    "group": "一次网",
    "name": "一次网瞬时热量",
    "header": "瞬时\n热量",
    "unit": "GJ/h",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "一次网累计热量",
    "header": "累计\n热量",
    "unit": "GJ",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "一次网瞬时流量",
    "header": "瞬时\n流量",
    "unit": "t/h",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "一次网累计流量",
    "header": "累计\n流量",
    "unit": "t",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "高温水供水温度",
    "header": "供水\n温度",
    "unit": "℃",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "高温水回水温度",
    "header": "回水\n温度",
    "unit": "℃",
    "decimals": 1,
  },
  {
    "group": "一次网",
    "name": "高温水供水压力",
    "header": "供水\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "一次网",
    "name": "高温水回水压力",
    "header": "回水\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "一次网",
    "name": "高温水除污器后压力",
    "header": "除污后\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "一次网",
    "name": "高温水供水调节阀反馈",
    "header": "调节阀\n反馈",
    "unit": "%",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二网供水温度",
    "header": "供水\n温度",
    "unit": "℃",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二网回水温度",
    "header": "回水\n温度",
    "unit": "℃",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二网供水压力",
    "header": "供水\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "二次网",
    "name": "二网回水压力",
    "header": "回水\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "二次网",
    "name": "二网循环泵出口压力",
    "header": "泵出口\n压力",
    "unit": "MPa",
    "decimals": 2,
  },
  {
    "group": "二次网",
    "name": "二网供水流量",
    "header": "供水\n流量",
    "unit": "t/h",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二网热量瞬时值",
    "header": "热量\n瞬时值",
    "unit": "GJ/h",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二次网累计热量",
    "header": "累计\n热量",
    "unit": "GJ",
    "decimals": 1,
  },
  {
    "group": "二次网",
    "name": "二次网累计流量",
    "header": "累计\n流量",
    "unit": "t",
    "decimals": 1,
  },
  {
    "group": "补水水箱",
    "name": "水箱水位",
    "header": "水箱\n水位",
    "unit": "mm",
    "decimals": 1,
  },
  {
    "group": "补水水箱",
    "name": "补水瞬时流量",
    "header": "瞬时\n流量",
    "unit": "t/h",
    "decimals": 1,
  },
  {
    "group": "补水水箱",
    "name": "补水流量累计",
    "header": "补水\n累计量",
    "unit": "t",
    "decimals": 1,
  },
  {
    "group": "补水水箱",
    "name": "补水电流",
    "header": "补水\n电流",
    "unit": "A",
    "decimals": 1,
  },
  {
    "group": "补水水箱",
    "name": "补水频率",
    "header": "补水\n频率",
    "unit": "Hz",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "主循环泵电流",
    "header": "主循环\n泵电流",
    "unit": "A",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "主循环泵频率",
    "header": "主循环\n泵频率",
    "unit": "Hz",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "循1电流",
    "header": "循1\n电流",
    "unit": "A",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "循1频率",
    "header": "循1\n频率",
    "unit": "Hz",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "循2电流",
    "header": "循2\n电流",
    "unit": "A",
    "decimals": 1,
  },
  {
    "group": "循环泵",
    "name": "循2频率",
    "header": "循2\n频率",
    "unit": "Hz",
    "decimals": 1,
  },
  {
    "group": "电能",
    "name": "电能正向有功电能_Ep",
    "header": "正向\n有功Ep",
    "unit": "kWh",
    "decimals": 1,
  },
];

List<Json> overviewTemplateColumns() => [
  for (final column in overviewReferenceColumns)
    {...column, 'id': screenIdentity()},
];

class LiveOverview extends StatefulWidget {
  const LiveOverview({
    super.key,
    required this.api,
    required this.definitions,
    required this.live,
    required this.online,
    this.canEdit = false,
    this.androidClient = false,
    this.stations = const [],
    this.onSubscriptionChanged,
  });
  final PlatformApi api;
  final Map<String, Json> definitions, live;
  final bool online, canEdit, androidClient;
  final List<String> stations;
  final ValueChanged<Set<String>>? onSubscriptionChanged;
  @override
  State<LiveOverview> createState() => _LiveOverviewState();
}

String overviewRowLabel(Json row, String key) =>
    (row[key]?.toString().trim().isNotEmpty ?? false)
    ? row[key].toString()
    : '未填写';

List<Json> filterOverviewRows(
  List<Json> rows,
  Map<String, Set<String>> selections,
  String search,
) => rows
    .where(
      (row) =>
          selections.entries.every(
            (entry) => entry.value.contains(overviewRowLabel(row, entry.key)),
          ) &&
          ['site', 'name', 'area', 'station']
              .map((key) => row[key] ?? '')
              .join(' ')
              .toLowerCase()
              .contains(search.trim().toLowerCase()),
    )
    .toList();

class _LiveOverviewState extends State<LiveOverview> {
  Json? config;
  String? error;
  bool loading = true, tableOnPhone = false;
  String group = '', selectedRow = '';
  final search = TextEditingController();
  final selections = <String, Set<String>>{};
  Set<String> subscribed = {};
  Map<String, Json> controlStates = {};
  Timer? controlTimer;
  int controlGeneration = 0;

  void restartControl() {
    controlTimer?.cancel();
    final generation = ++controlGeneration;
    controlStates = {};
    if ((config?['control'] as Map?)?['enabled'] != true || !widget.online) {
      return;
    }
    unawaited(pollControl(generation));
  }

  Future<void> pollControl(int generation) async {
    final revision = config?['revision'];
    try {
      final result = await widget.api
          .request('GET', '$overviewPath/control-status')
          .timeout(const Duration(seconds: 4));
      if (!mounted || generation != controlGeneration) return;
      setState(() {
        controlStates = result['revision'] == revision && result['rows'] is Map
            ? {
                for (final e in (result['rows'] as Map).entries)
                  if (e.key is String && e.value is Json)
                    e.key as String: e.value as Json,
              }
            : {};
      });
    } catch (_) {
      if (!mounted || generation != controlGeneration) return;
      setState(() => controlStates = {});
    }
    if (mounted && generation == controlGeneration) {
      controlTimer = Timer(
        const Duration(seconds: 2),
        () => pollControl(generation),
      );
    }
  }

  @override
  void didUpdateWidget(covariant LiveOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.online != widget.online || oldWidget.api != widget.api) {
      restartControl();
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    controlGeneration++;
    controlTimer?.cancel();
    search.dispose();
    super.dispose();
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
          restartControl();
          loading = false;
          if (!objects(c['columns']).any((v) => v['group'] == group)) {
            group = '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
          config = null;
          restartControl();
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
        restartControl();
        group = '';
      });
    }
  }

  void subscribe(List<Json> rows, List<Json> columns) {
    final outdoor = (config?['outdoor'] as Map?)?['point_id'];
    final ids = <String>{
      if (outdoor is String && widget.definitions.containsKey(outdoor)) outdoor,
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

  String pointUnit(String? id) =>
      (widget.live[id]?['unit'] ?? widget.definitions[id]?['unit'] ?? '')
          .toString();
  String columnUnit(Json col, List<Json> rows) {
    final units = <String>{
      for (final r in rows)
        if ((r['bindings'] as Map?)?[col['id']] case final String id)
          if (widget.definitions.containsKey(id)) pointUnit(id),
    };
    return units.length > 1
        ? '多单位'
        : units.firstOrNull ?? col['unit']?.toString() ?? '';
  }

  ProcessValue value(
    String id,
    int decimals, {
    bool showUnit = true,
    String fallbackUnit = '',
  }) => processValue(
    ScreenElement({
      'kind': 'value',
      'point_id': id,
      'decimals': decimals,
      'show_unit': showUnit,
      'unit_override': pointUnit(id).isEmpty ? fallbackUnit : '',
    }),
    ScreenDocument(id: 'overview', name: '数据总览', station: ''),
    widget.definitions,
    widget.live,
    widget.online,
  );
  ProcessValue rowValue(Json row, Json col, String? headerUnit) {
    final id = (row['bindings'] as Map?)?[col['id']] as String? ?? '';
    return value(
      id,
      col['decimals'] as int? ?? 2,
      showUnit: headerUnit == null || pointUnit(id) != headerUnit,
      fallbackUnit: headerUnit == null ? col['unit'] as String? ?? '' : '',
    );
  }

  Widget reading(Json row, Json col, {String? headerUnit}) {
    final v = rowValue(row, col, headerUnit);
    return Tooltip(
      message:
          '${overviewRowLabel(row, 'name')} · ${overviewRowLabel(row, 'area')}\n${col['name']}\n${v.tooltip}\n${v.text}',
      child: Text(
        v.text,
        maxLines: headerUnit == null ? 2 : 1,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: numericStyle.copyWith(
          fontSize: headerUnit == null ? 14 : 12.5,
          fontWeight: v.good ? FontWeight.w500 : FontWeight.normal,
          color: v.good ? ProcessStyle.ink : ProcessStyle.muted,
        ),
      ),
    );
  }

  Future<void> filter(String key, String label, List<Json> rows) async {
    final values = rows.map((r) => overviewRowLabel(r, key)).toSet().toList();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (_) => OverviewFilterDialog(
        label: label,
        values: values,
        selected: selections[key] ?? values.toSet(),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (result.length == values.length) {
          selections.remove(key);
        } else {
          selections[key] = result;
        }
      });
    }
  }

  String dataTime([Iterable<String>? pointIDs]) {
    final times =
        (pointIDs ?? subscribed)
            .map(
              (id) => DateTime.tryParse(
                widget.live[id]?['source_time']?.toString() ?? '',
              ),
            )
            .whereType<DateTime>()
            .toList()
          ..sort();
    if (times.isEmpty) return '—';
    final t = times.last.toUtc().add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final phone = widget.androidClient || box.maxWidth < 640;
      final allRows = objects(config?['rows']),
          cols = objects(config?['columns']);
      final rows = filterOverviewRows(allRows, selections, search.text);
      final groups = cols.map((c) => c['group'] as String).toSet().toList();
      final visibleCols = cols
          .where((c) => group.isEmpty || c['group'] == group)
          .toList();
      final selected =
          rows.where((r) => r['id'] == selectedRow).firstOrNull ??
          rows.firstOrNull;
      subscribe(phone && !tableOnPhone ? [?selected] : rows, visibleCols);
      final units = {
        for (final c in visibleCols) c['id'] as String: columnUnit(c, rows),
      };
      final single = widget.androidClient && !tableOnPhone;
      final exportRows = single ? [?selected] : rows;
      final exportButton = IconButton(
        tooltip: single ? '导出当前站区 CSV' : '导出筛选结果 CSV',
        icon: const Icon(Icons.download_outlined),
        onPressed: exportRows.isEmpty
            ? null
            : () async {
                try {
                  final csv = TableCsv()
                    ..add([
                      '站所',
                      '换热站名称',
                      '区域',
                      for (final c in visibleCols)
                        '${c['group']} / ${c['name']}${(units[c['id']] ?? '').isEmpty ? '' : ' (${units[c['id']]})'}',
                    ]);
                  for (final r in exportRows) {
                    csv.add([
                      for (final k in ['site', 'name', 'area'])
                        overviewRowLabel(r, k),
                      for (final c in visibleCols)
                        rowValue(r, c, units[c['id']]).text,
                    ]);
                  }
                  await csv.save(
                    '数据总览-${DateTime.now().toIso8601String().substring(0, 10)}.csv',
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
                  }
                }
              },
      );
      final outdoor = value(
        (config?['outdoor'] as Map?)?['point_id'] as String? ?? '',
        1,
      );
      if (widget.androidClient && !tableOnPhone) {
        final stationTime = dataTime([
          for (final id in (selected?['bindings'] as Map? ?? {}).values)
            if (id is String && widget.definitions.containsKey(id)) id,
        ]);
        return ColoredBox(
          color: const Color(0xfff1f5f7),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xff163850), Color(0xff175966)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.sensors,
                          size: 16,
                          color: Color(0xff8cdfd2),
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            '实时总览',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        exportButton,
                        IconButton(
                          tooltip: '刷新总览配置',
                          onPressed: loading ? null : load,
                          icon: const Icon(
                            Icons.refresh,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          tooltip: '切换完整表格',
                          onPressed: () => setState(() => tableOnPhone = true),
                          icon: const Icon(
                            Icons.table_chart_outlined,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selected?['id'],
                        isExpanded: true,
                        isDense: true,
                        iconEnabledColor: Colors.white,
                        hint: const Text(
                          '选择站区',
                          style: TextStyle(color: Colors.white70),
                        ),
                        selectedItemBuilder: (_) => [
                          for (final r in rows)
                            Text(
                              [r['name'], r['area']]
                                  .whereType<String>()
                                  .where((s) => s.isNotEmpty)
                                  .join(' · '),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                        items: [
                          for (final r in rows)
                            DropdownMenuItem(
                              value: r['id'] as String,
                              child: Text(
                                [r['site'], r['name'], r['area']]
                                    .whereType<String>()
                                    .where((s) => s.isNotEmpty)
                                    .join(' / '),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (id) =>
                            setState(() => selectedRow = id ?? ''),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 14,
                      runSpacing: 2,
                      children: [
                        if ((config?['control'] as Map?)?['enabled'] == true)
                          Text(
                            '${controlStates[selected?['id']]?['label'] ?? '状态未知'}',
                            style: TextStyle(
                              color:
                                  controlStates[selected?['id']]?['active'] ==
                                      true
                                  ? const Color(0xff8ee0a6)
                                  : const Color(0xffd3e9ec),
                              fontSize: 12,
                            ),
                          ),
                        Text(
                          '室外温度  ${outdoor.text}',
                          style: const TextStyle(
                            color: Color(0xffd3e9ec),
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          "${widget.online ? '数据时间' : '连接中断'}  $stationTime",
                          style: TextStyle(
                            color: widget.online
                                ? const Color(0xffd3e9ec)
                                : Colors.amberAccent,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? Center(child: Text('总览加载失败：$error'))
                    : cols.isEmpty || allRows.isEmpty
                    ? const Center(child: Text('数据总览尚未配置'))
                    : selected == null
                    ? const Center(child: Text('没有符合筛选条件的站点'))
                    : ListView(
                        key: PageStorageKey(
                          'overview-station-${selected['id']}',
                        ),
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        children: [
                          for (final g
                              in visibleCols.map((c) => c['group']).toSet())
                            Container(
                              margin: const EdgeInsets.only(top: 7),
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 5),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xffe1e9ed),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 3,
                                        height: 13,
                                        decoration: BoxDecoration(
                                          color: const Color(0xff258981),
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          g as String,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xff225459),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${visibleCols.where((c) => c['group'] == g).length} 项',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: ProcessStyle.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  for (final c in visibleCols.where(
                                    (c) => c['group'] == g,
                                  ))
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 32,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: Text(
                                              c['name'] as String,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                color: Color(0xff475d69),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            flex: 2,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: reading(selected, c),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      }
      return ColoredBox(
        color: RuntimeStyle.paper,
        child: Padding(
          padding: EdgeInsets.all(phone ? 8 : 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!phone) const QueryHeading(title: '数据总览'),
              QueryToolbar(
                key: const Key('overview-query-toolbar'),
                maxHeight: box.maxHeight * .5,
                fields: [
                  SizedBox(
                    width: phone ? 152 : 170,
                    height: phone ? 44 : 34,
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        hintText: '搜索站所、站名、区域',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  SizedBox(
                    width: phone ? 116 : 128,
                    height: phone ? 44 : 34,
                    child: DropdownButton<String>(
                      value: group,
                      isDense: true,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('全部指标', style: TextStyle(fontSize: 12)),
                        ),
                        for (final g in groups)
                          DropdownMenuItem(
                            value: g,
                            child: Text(
                              g,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => group = v ?? ''),
                    ),
                  ),
                  for (final e in {
                    'site': '站所',
                    'name': '站名',
                    'area': '区域',
                  }.entries)
                    OutlinedButton(
                      onPressed: allRows.isEmpty
                          ? null
                          : () => filter(e.key, e.value, allRows),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(phone ? 82 : 110, phone ? 44 : 34),
                        visualDensity: VisualDensity.standard,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(
                        '${e.value} ${selections[e.key] == null ? '全部' : '${selections[e.key]!.length}项'} ▾',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                actions: [
                  TextButton(
                    onPressed: () => setState(() {
                      selections.clear();
                      search.clear();
                      group = '';
                    }),
                    child: const Text('重置筛选'),
                  ),
                  exportButton,
                  IconButton(
                    tooltip: '刷新总览配置',
                    onPressed: loading ? null : load,
                    icon: const Icon(Icons.refresh, size: 19),
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
                        size: 19,
                      ),
                    ),
                  if (widget.canEdit)
                    FilledButton.tonalIcon(
                      onPressed: config == null ? null : edit,
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('配置总览'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: const Color(0xffdce3e8),
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: outdoor.tooltip,
                        child: Text(
                          '室外温度  ${outdoor.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    if (!phone)
                      const Text(
                        '实时运行数据',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        '${widget.online ? '数据时间' : '连接中断'}  ${dataTime()}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 11,
                          color: ProcessStyle.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? Center(child: Text('总览加载失败：$error'))
                    : cols.isEmpty || allRows.isEmpty
                    ? Center(
                        child: Text(
                          widget.canEdit ? '尚未配置数据总览，请打开“配置总览”' : '数据总览尚未配置',
                        ),
                      )
                    : rows.isEmpty
                    ? const Center(child: Text('没有符合筛选条件的站点'))
                    : phone && !tableOnPhone
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 6),
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
                                    '${overviewRowLabel(r, 'site')} / ${r['name']} / ${overviewRowLabel(r, 'area')}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (id) =>
                                setState(() => selectedRow = id ?? ''),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final g
                                    in visibleCols
                                        .map((c) => c['group'] as String)
                                        .toSet()) ...[
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      g,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: ProcessStyle.ink,
                                      ),
                                    ),
                                  ),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final c in visibleCols.where(
                                        (c) => c['group'] == g,
                                      ))
                                        Container(
                                          width: (box.maxWidth - 22) / 2,
                                          constraints: const BoxConstraints(
                                            minHeight: 64,
                                          ),
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            border: Border.all(
                                              color: ProcessStyle.line,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                c['name'] as String,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: ProcessStyle.muted,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
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
                        units: units,
                        controlStates: controlStates,
                        showControl:
                            (config?['control'] as Map?)?['enabled'] == true,
                        reading: (r, c) =>
                            reading(r, c, headerUnit: units[c['id']]),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${rows.length} / ${allRows.length} 行 · ${visibleCols.length} 项指标${widget.online ? '' : ' · 连接中断，实时数据不可用'}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: ProcessStyle.muted,
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

class OverviewFilterDialog extends StatefulWidget {
  const OverviewFilterDialog({
    super.key,
    required this.label,
    required this.values,
    required this.selected,
  });
  final String label;
  final List<String> values;
  final Set<String> selected;
  @override
  State<OverviewFilterDialog> createState() => _OverviewFilterDialogState();
}

class _OverviewFilterDialogState extends State<OverviewFilterDialog> {
  late final chosen = Set<String>.from(widget.selected);
  String search = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.label}筛选'),
    content: SizedBox(
      width: 300,
      height: 340,
      child: Column(
        children: [
          TextField(
            decoration: const InputDecoration(isDense: true, hintText: '搜索选项'),
            onChanged: (v) => setState(() => search = v),
          ),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => chosen.addAll(widget.values)),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: () => setState(chosen.clear),
                child: const Text('清空'),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                for (final v in widget.values.where((v) => v.contains(search)))
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(v),
                    value: chosen.contains(v),
                    onChanged: (yes) => setState(() {
                      if (yes == true) {
                        chosen.add(v);
                      } else {
                        chosen.remove(v);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, chosen),
        child: const Text('应用筛选'),
      ),
    ],
  );
}

/// Ranges are computed from the current visible order and stable point IDs.
/// Missing bindings and equal values belonging to different points never merge.
List<({int start, int end, int column})> overviewMeasurementSpans(
  List<Json> rows,
  List<Json> columns,
) {
  final result = <({int start, int end, int column})>[];
  for (var column = 0; column < columns.length; column++) {
    final id = columns[column]['id'];
    var start = 0;
    while (start < rows.length) {
      final point = (rows[start]['bindings'] as Map?)?[id];
      var end = start + 1;
      while (point is String &&
          point.isNotEmpty &&
          end < rows.length &&
          (rows[end]['bindings'] as Map?)?[id] == point) {
        end++;
      }
      if (end - start > 1) result.add((start: start, end: end, column: column));
      start = end;
    }
  }
  return result;
}

class OverviewControlArea extends StatelessWidget {
  const OverviewControlArea({super.key, required this.child, this.state});
  final Widget child;
  final Json? state;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: '${state?['label'] ?? '状态未知'}',
    child: Semantics(
      label: '${state?['label'] ?? '状态未知'}',
      child: ColoredBox(
        color: state?['active'] == true
            ? const Color(0xffbde5c7)
            : Colors.transparent,
        child: child,
      ),
    ),
  );
}

class OverviewTable extends StatefulWidget {
  const OverviewTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.reading,
    this.units = const {},
    this.controlStates = const {},
    this.showControl = false,
  });
  final List<Json> columns, rows;
  final Map<String, String> units;
  final Map<String, Json> controlStates;
  final bool showControl;
  final Widget Function(Json, Json) reading;
  @override
  State<OverviewTable> createState() => _OverviewTableState();
}

class _OverviewTableState extends State<OverviewTable> {
  final horizontal = ScrollController();
  final vertical = ScrollController();
  String? hoveredRow;
  @override
  void dispose() {
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final phone = box.maxWidth < 640;
      final siteWidth = phone ? 54.0 : 76.0,
          nameWidth = phone ? 102.0 : 140.0,
          areaWidth = phone ? 60.0 : 76.0;
      final fixed = siteWidth + nameWidth + areaWidth,
          rowHeight = phone ? 32.0 : 26.0;
      // Keep the complete matrix in the available width. Each reading scales
      // within its own cell, so long cumulative values remain fully visible.
      final cellWidth =
          math.max(0.0, box.maxWidth - fixed) /
          math.max(1, widget.columns.length);
      final width = widget.columns.length * cellWidth;
      final groups = <(String, int)>[];
      for (final c in widget.columns) {
        final name = c['group'] as String;
        if (groups.isNotEmpty && groups.last.$1 == name) {
          final p = groups.removeLast();
          groups.add((name, p.$2 + 1));
        } else {
          groups.add((name, 1));
        }
      }
      final spans =
          <({int start, int end, String text, double left, double width})>[];
      final hoveredIndex = widget.rows.indexWhere((r) => r['id'] == hoveredRow);
      final measurementSpans = overviewMeasurementSpans(
        widget.rows,
        widget.columns,
      );
      final measurements = <(int, int), ({int start, int end, int column})>{
        for (final span in measurementSpans)
          for (var i = span.start; i < span.end; i++) (i, span.column): span,
      };
      final activeSpans = <String, (int, int)>{};
      for (final key in ['site', 'name']) {
        var start = 0;
        while (start < widget.rows.length) {
          final row = widget.rows[start];
          final text = overviewRowLabel(row, key);
          final site = overviewRowLabel(row, 'site');
          var end = start + 1;
          while (end < widget.rows.length &&
              overviewRowLabel(widget.rows[end], key) == text &&
              overviewRowLabel(widget.rows[end], 'site') == site) {
            end++;
          }
          if (start <= hoveredIndex && hoveredIndex < end) {
            activeSpans[key] = (start, end);
          }
          spans.add((
            start: start,
            end: end,
            text: text,
            left: key == 'site' ? 0.0 : siteWidth,
            width: key == 'site' ? siteWidth : nameWidth,
          ));
          start = end;
        }
      }
      bool spanActive(String key, int index) {
        final span = activeSpans[key];
        return span != null && span.$1 <= index && index < span.$2;
      }

      // Labels share the row scroll offset while the painted row backgrounds
      // retain their individual hover and border hit areas.
      Widget mergedLabels() => IgnorePointer(
        child: LayoutBuilder(
          builder: (context, viewport) => AnimatedBuilder(
            animation: vertical,
            builder: (context, _) {
              final offset = vertical.hasClients ? vertical.offset : 0.0;
              return Stack(
                children: [
                  for (final span in spans)
                    if (span.end * rowHeight > offset &&
                        span.start * rowHeight < offset + viewport.maxHeight)
                      Positioned(
                        left: span.left,
                        width: span.width,
                        top: span.start * rowHeight - offset,
                        height: (span.end - span.start) * rowHeight,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              span.text,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: ProcessStyle.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      );
      Widget cell(
        Widget child,
        double width, {
        double? height,
        bool border = true,
        Color? color,
      }) => Container(
        width: width,
        height: height ?? rowHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: color,
          border: Border(
            right: const BorderSide(color: ProcessStyle.line, width: .5),
            bottom: BorderSide(
              color: border ? ProcessStyle.line : Colors.transparent,
              width: .5,
            ),
          ),
        ),
        child: child,
      );
      Widget label(
        String text,
        double width, {
        bool border = true,
        bool active = false,
      }) => cell(
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: ProcessStyle.ink),
        ),
        width,
        border: border,
        color: active ? const Color(0xffc1e1f8) : const Color(0xffe8ecef),
      );
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: math.min(box.maxHeight, 82 + widget.rows.length * rowHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: ProcessStyle.line),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    for (final e in {
                      '站所': siteWidth,
                      '换热站名称': nameWidth,
                      '区域': areaWidth,
                    }.entries)
                      cell(
                        Text(
                          e.key,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        e.value,
                        height: 80,
                        color: const Color(0xffe8ecef),
                      ),
                    Expanded(
                      child: Scrollbar(
                        controller: horizontal,
                        thumbVisibility: false,
                        child: SingleChildScrollView(
                          controller: horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: width,
                            height: 80,
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    for (final g in groups)
                                      cell(
                                        Text(
                                          g.$1,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        g.$2 * cellWidth,
                                        height: 26,
                                        color: const Color(0xffdce3e8),
                                      ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    for (final c in widget.columns)
                                      cell(
                                        Tooltip(
                                          message: c['name'] as String,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  (c['header'] as String?)
                                                              ?.isNotEmpty ==
                                                          true
                                                      ? c['header'] as String
                                                      : c['name'] as String,
                                                  maxLines: 2,
                                                  textAlign: TextAlign.center,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    height: 1.2,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  widget.units[c['id']] ?? '',
                                                  maxLines: 1,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    color: ProcessStyle.muted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        cellWidth,
                                        height: 46,
                                      ),
                                  ],
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
                      builder: (context, _) => Stack(
                        fit: StackFit.expand,
                        children: [
                          ListView.builder(
                            controller: vertical,
                            padding: EdgeInsets.zero,
                            itemExtent: rowHeight,
                            itemCount: widget.rows.length,
                            itemBuilder: (context, i) {
                              final r = widget.rows[i],
                                  next = i + 1 < widget.rows.length
                                      ? widget.rows[i + 1]
                                      : null;
                              bool same(Json? other, String key) =>
                                  other != null &&
                                  overviewRowLabel(other, key) ==
                                      overviewRowLabel(r, key);
                              final id = r['id'] as String;
                              final active = hoveredRow == id;
                              return MouseRegion(
                                key: ValueKey(id),
                                onEnter: (_) => setState(() => hoveredRow = id),
                                onExit: (_) {
                                  if (hoveredRow == id) {
                                    setState(() => hoveredRow = null);
                                  }
                                },
                                child: ColoredBox(
                                  color: active
                                      ? const Color(0xffdaf0ff)
                                      : i.isEven
                                      ? Colors.white
                                      : const Color(0xfff1f3f5),
                                  child: Row(
                                    children: [
                                      label(
                                        '',
                                        siteWidth,
                                        active: spanActive('site', i),
                                        border: !same(next, 'site'),
                                      ),
                                      label(
                                        '',
                                        nameWidth,
                                        active: spanActive('name', i),
                                        border:
                                            !same(next, 'site') ||
                                            !same(next, 'name'),
                                      ),
                                      if (widget.showControl)
                                        OverviewControlArea(
                                          state: widget.controlStates[id],
                                          child: cell(
                                            Text(
                                              overviewRowLabel(r, 'area'),
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                color: ProcessStyle.ink,
                                              ),
                                            ),
                                            areaWidth,
                                          ),
                                        )
                                      else
                                        label(
                                          overviewRowLabel(r, 'area'),
                                          areaWidth,
                                          active: active,
                                        ),
                                      Expanded(
                                        child: ClipRect(
                                          child: SizedBox(
                                            height: rowHeight,
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
                                                    for (
                                                      var ci = 0;
                                                      ci <
                                                          widget.columns.length;
                                                      ci++
                                                    )
                                                      cell(
                                                        Opacity(
                                                          opacity:
                                                              measurements
                                                                  .containsKey((
                                                                    i,
                                                                    ci,
                                                                  ))
                                                              ? 0
                                                              : 1,
                                                          child: FittedBox(
                                                            fit: BoxFit
                                                                .scaleDown,
                                                            child: widget.reading(
                                                              r,
                                                              widget
                                                                  .columns[ci],
                                                            ),
                                                          ),
                                                        ),
                                                        cellWidth,
                                                        border:
                                                            measurements[(
                                                                  i,
                                                                  ci,
                                                                )] ==
                                                                null ||
                                                            measurements[(
                                                                      i,
                                                                      ci,
                                                                    )]!
                                                                    .end ==
                                                                i + 1,
                                                        color: switch (measurements[(
                                                          i,
                                                          ci,
                                                        )]) {
                                                          final span? =>
                                                            span.start <=
                                                                        hoveredIndex &&
                                                                    hoveredIndex <
                                                                        span.end
                                                                ? const Color(
                                                                    0xffdaf0ff,
                                                                  )
                                                                : Colors.white,
                                                          null => null,
                                                        },
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          mergedLabels(),
                          Positioned.fill(
                            left: fixed,
                            child: IgnorePointer(
                              child: ClipRect(
                                child: LayoutBuilder(
                                  builder: (context, viewport) => AnimatedBuilder(
                                    animation: vertical,
                                    builder: (context, _) {
                                      final offset = vertical.hasClients
                                          ? vertical.offset
                                          : 0.0;
                                      return Stack(
                                        children: [
                                          for (final span in measurementSpans)
                                            if (span.end * rowHeight > offset &&
                                                span.start * rowHeight <
                                                    offset + viewport.maxHeight)
                                              Positioned(
                                                key: ValueKey(
                                                  'merged-${widget.rows[span.start]['id']}-${widget.columns[span.column]['id']}',
                                                ),
                                                left:
                                                    span.column * cellWidth -
                                                    (horizontal.hasClients
                                                        ? horizontal.offset
                                                        : 0),
                                                width: cellWidth,
                                                top:
                                                    span.start * rowHeight -
                                                    offset,
                                                height:
                                                    (span.end - span.start) *
                                                    rowHeight,
                                                child: Center(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 2,
                                                        ),
                                                    child: FittedBox(
                                                      fit: BoxFit.scaleDown,
                                                      child: widget.reading(
                                                        widget.rows[span.start],
                                                        widget.columns[span
                                                            .column],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
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
  int formVersion = 0;
  Future<List<Json>?> chooseRows(
    List<Json> candidates, {
    required bool importing,
  }) => selectTransferRows(
    context,
    rows: candidates,
    title: importing ? '选择导入站区' : '选择导出站区',
    description: '文件包含所选站区、全部指标列和室外温度配置。',
    action: importing ? '下一步' : '导出 JSON',
    allowEmpty: true,
    label: (r) => [
      r['site'],
      r['name'],
      r['area'],
    ].whereType<String>().where((s) => s.isNotEmpty).join(' / '),
    detail: (r) => '归属站点 · ${r['station']}',
  );
  Future<void> transfer(bool importing) async {
    try {
      if (!importing) {
        final chosen = await chooseRows(rows, importing: false);
        if (chosen == null || !mounted) return;
        final data = encodeOverview(
          columns,
          chosen,
          draft['outdoor'],
          control: draft['control'],
        );
        final saved = await saveFile(data, 'live-overview.json');
        if (saved && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(kIsWeb ? '已发起总览配置下载' : '已导出总览配置')),
          );
        }
        return;
      }
      final file = await pickProcessFile(image: false, jsonLabel: '总览配置 JSON');
      if (file == null || !mounted) return;
      final next = OverviewImport.decode(file.bytes, widget.definitions);
      final chosen = await chooseRows(next.rows, importing: true);
      if (chosen == null || !mounted) return;
      final stations = chosen
          .map((r) => r['station'])
          .toSet()
          .difference(widget.stations.toSet());
      final oldIDs = rows.map((r) => r['id']).toSet();
      final merged = next.merge(columns, rows, chosen);
      final canMerge =
          merged.columns.length <= 64 &&
          merged.rows.length <= 256 &&
          merged.rows.length * merged.columns.length <= 8192;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('预览导入总览配置'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Text(
                [
                  '将用所选 ${chosen.length} 行、${next.columns.length} 列和室外温度配置替换整个草稿（当前 ${rows.length} 行、${columns.length} 列）。',
                  '所选站区已匹配 ${chosen.fold<int>(0, (sum, r) => sum + (r['bindings'] as Map).length)} 个指标绑定。',
                  if (canMerge)
                    '也可按行、列标识合并，更新 ${chosen.where((r) => oldIDs.contains(r['id'])).length} 行，新增 ${chosen.where((r) => !oldIDs.contains(r['id'])).length} 行。保留其他行、自定义列及绑定；同步文件的标准列、室外温度和接管状态配置。',
                  if (next.missing.isNotEmpty)
                    '全文件有 ${next.missing.length} 处未唯一匹配，对应位置将留空：\n${next.missing.join('\n')}',
                  if (stations.isNotEmpty)
                    '请在保存前核对授权归属站点：${stations.join('、')}',
                  '确认后可继续编辑，点击“保存总览”才会写入工程。',
                ].join('\n\n'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('整表替换'),
            ),
            if (canMerge)
              FilledButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('合并所选行'),
              ),
          ],
        ),
      );
      if (confirmed != null && mounted) {
        setState(() {
          if (confirmed) {
            columns = next.columns;
          } else {
            columns = merged.columns;
          }
          draft['outdoor'] = next.outdoor;
          if (next.control != null) draft['control'] = next.control;
          rows = confirmed ? chosen : merged.rows;
          rowID = '';
          error = null;
          formVersion++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

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
          maxLines: key == 'header' ? 2 : 1,
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
      title: Row(
        children: [
          const Expanded(child: Text('数据总览配置')),
          IconButton(
            tooltip: '导入总览配置',
            onPressed: saving ? null : () => transfer(true),
            icon: const Icon(Icons.file_open),
          ),
          IconButton(
            tooltip: '导出总览配置',
            onPressed: saving ? null : () => transfer(false),
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
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
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('室外温度'),
                subtitle: Text(
                  widget
                          .definitions[(draft['outdoor']
                              as Map?)?['point_id']]?['name']
                          ?.toString() ??
                      '未绑定',
                ),
                trailing: IconButton(
                  tooltip: '清除室外温度绑定',
                  icon: const Icon(Icons.link_off),
                  onPressed: () =>
                      setState(() => draft['outdoor'] = <String, dynamic>{}),
                ),
                onTap: () async {
                  final id = await showDialog<String>(
                    context: context,
                    builder: (_) => GisPointPicker(
                      definitions: widget.definitions,
                      title: '选择室外温度变量',
                    ),
                  );
                  if (id != null && mounted) {
                    setState(() => draft['outdoor'] = {'point_id': id});
                  }
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in {
                    0: '指标列',
                    1: '站点行',
                    2: '变量绑定',
                    3: '接管状态',
                  }.entries)
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
                            'site': '',
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
                child: tab == 3
                    ? ListView(
                        children: [
                          SwitchListTile(
                            title: const Text('显示接管状态'),
                            subtitle: const Text('只读取状态，不提供模式切换或设备控制。'),
                            value:
                                (draft['control'] as Map?)?['enabled'] == true,
                            onChanged: (v) => setState(
                              () =>
                                  (draft['control'] ??=
                                          <String, dynamic>{})['enabled'] =
                                      v,
                            ),
                          ),
                          TextFormField(
                            key: ValueKey('control-url-$formVersion'),
                            initialValue:
                                '${(draft['control'] as Map?)?['base_url'] ?? ''}',
                            decoration: const InputDecoration(
                              labelText: '状态服务地址',
                              hintText: 'http://172.16.1.7:8004',
                              helperText: '由本软件后台读取内网服务；保存后生效。',
                            ),
                            onChanged: (v) =>
                                (draft['control'] ??=
                                    <String, dynamic>{})['base_url'] = v
                                    .trim(),
                          ),
                          const SizedBox(height: 16),
                          for (final r in rows)
                            Padding(
                              key: ValueKey('control-${r['id']}-$formVersion'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${r['name']} · ${r['area']}'),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    children: [
                                      field(
                                        r['control'] ??= <String, dynamic>{},
                                        'station',
                                        '状态服务站名',
                                        width: 260,
                                      ),
                                      field(
                                        r['control'] ??= <String, dynamic>{},
                                        'zone',
                                        '状态服务区名',
                                        width: 220,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                        ],
                      )
                    : tab == 0
                    ? ListView.builder(
                        itemCount: columns.length,
                        itemBuilder: (_, i) {
                          final c = columns[i];
                          return Padding(
                            key: ValueKey((formVersion, c['id'])),
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                field(c, 'group', '分组', width: 180),
                                field(c, 'name', '指标名称', width: 200),
                                field(c, 'header', '紧凑表头（可换行）', width: 150),
                                field(c, 'unit', '未绑定时表头单位', width: 130),
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
                            key: ValueKey((formVersion, r['id'])),
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                field(r, 'site', '站所'),
                                field(r, 'name', '换热站名称'),
                                field(r, 'area', '区域'),
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
