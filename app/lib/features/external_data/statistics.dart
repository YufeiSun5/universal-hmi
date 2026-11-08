import 'report_designer.dart';
import '../../shared/report_style.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/report_number.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';
import '../trend.dart';
import 'catalog.dart';
import 'statistics_columns.dart';
import 'statistics_grid.dart';
import 'daily_reading.dart';
import 'comparison.dart';
import 'heat_settlement.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/date_time_field.dart';

class EnergyWorkspace extends StatefulWidget {
  const EnergyWorkspace({
    super.key,
    required this.catalog,
    this.selectedID,
    this.onSelected,
    this.showDirectory = true,
  });
  final ExternalCatalog catalog;
  final String? selectedID;
  final ValueChanged<String?>? onSelected;
  final bool showDirectory;
  @override
  State<EnergyWorkspace> createState() => _EnergyWorkspaceState();
}

class _EnergyWorkspaceState extends State<EnergyWorkspace> {
  String? selected;
  @override
  void initState() {
    super.initState();
    if (!widget.catalog.loaded) Future.microtask(widget.catalog.load);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.catalog,
    builder: (context, _) {
      final c = widget.catalog;
      final screens = c.energyScreens;
      final id = widget.onSelected != null ? widget.selectedID : selected;
      final screen =
          screens.where((s) => s['id'] == id).firstOrNull ??
          screens.firstOrNull;
      final body = screen == null
          ? const Center(child: Text('暂无已授权的能耗画面'))
          : ReportStyleHost(
              key: ValueKey(screen['id']),
              screen: screen,
              child: Builder(
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (c.canDevelop)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                          child: ReportStyleAction(catalog: c, screen: screen),
                        ),
                      ),
                    if (c.loading) const LinearProgressIndicator(),
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(c.error!),
                      ),
                    Expanded(
                      child: screen['kind'] == 'settlement'
                          ? HeatSettlementQuery(
                              key: ValueKey(screen['id']),
                              api: c.api,
                              screen: screen,
                            )
                          : screen['kind'] == 'comparison'
                          ? ComparisonQuery(
                              key: ValueKey(screen['id']),
                              api: c.api,
                              screen: screen,
                            )
                          : StatisticsQuery(
                              key: ValueKey(screen['id']),
                              api: c.api,
                              screen: screen,
                            ),
                    ),
                  ],
                ),
              ),
            );
      if (!widget.showDirectory) return body;
      return Row(
        children: [
          SizedBox(
            width: 248,
            child: ExternalDataPanel(
              catalog: c,
              title: '能耗目录',
              kinds: const {'energy', 'comparison'},
              selectedID: screen?['id'] as String?,
              onOpen: (s) {
                setState(() => selected = s?['id'] as String?);
                widget.onSelected?.call(selected);
              },
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      );
    },
  );
}

class StatisticsQuery extends StatefulWidget {
  const StatisticsQuery({
    super.key,
    required this.api,
    required this.screen,
    this.actions = const [],
    this.autoQuery = true,
    this.development = false,
  });
  final PlatformApi api;
  final Json screen;
  final List<Widget> actions;
  final bool autoQuery;
  final bool development;
  @override
  State<StatisticsQuery> createState() => _StatisticsQueryState();
}

class _StatisticsQueryState extends State<StatisticsQuery> {
  final start = TextEditingController(
    text: DateTime.now()
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .substring(0, 10),
  );
  late final end = TextEditingController(text: start.text);
  List<Json> stations = [], rows = [];
  String station = '', metric = 'electricity';
  late String mode = energy ? 'current' : '${widget.screen['kind']}';
  bool get energy => widget.screen['kind'] == 'energy';
  bool get periodReport =>
      const {'monthly', 'season'}.contains(widget.screen['kind']);
  String get queryID => '${widget.screen['query_id'] ?? widget.screen['id']}';
  bool loading = true, busy = false, queried = false;
  String? error;
  int generation = 0;
  int decimals = 2;
  int layoutRevision = -1;
  late List<Json> layout;
  Timer? layoutTimer;
  bool refreshingLayout = false;
  String? layoutError;

  void applyLayout(Json data, String versionKey) {
    final version = data[versionKey] as int? ?? 0;
    if (version <= layoutRevision) return;
    layout = periodReport
        ? [
            {'key': 'date', 'label': '统计周期', 'visible': true},
            {'key': 'station', 'label': '站点', 'visible': true},
            {'key': 'label', 'label': '指标', 'visible': true},
            {'key': 'unit', 'label': '单位', 'visible': true},
            {'key': 'day_usage', 'label': '用量', 'visible': true},
          ]
        : statisticsLayout({...data, 'kind': widget.screen['kind']});
    layoutRevision = version;
  }

  Future<void> refreshLayout() async {
    if (refreshingLayout) return;
    refreshingLayout = true;
    try {
      final data = await widget.api.request('GET', '/api/v1/external/screens');
      if (!mounted) return;
      final screen = objects(
        data['items'],
      ).where((s) => s['id'] == queryID).firstOrNull;
      setState(() {
        if (screen == null) {
          generation++;
          busy = false;
          rows = [];
          layoutError = '画面已删除或无权访问';
        } else {
          applyLayout(screen, 'revision');
          layoutError = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => layoutError = '页面配置暂不可用，请重试');
    } finally {
      refreshingLayout = false;
    }
  }

  @override
  void initState() {
    super.initState();
    applyLayout(widget.screen, 'revision');
    layoutTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => refreshLayout(),
    );
    load();
  }

  @override
  void dispose() {
    generation++;
    layoutTimer?.cancel();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final seq = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/external/screens/$queryID/stations',
      );
      if (!mounted || seq != generation) return;
      setState(() {
        stations = objects(data['items']);
        station = energy ? '' : stations.firstOrNull?['code'] as String? ?? '';
        loading = false;
      });
      if (widget.autoQuery && stations.isNotEmpty) await query();
    } catch (e) {
      if (mounted && seq == generation) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  void changed() {
    generation++;
    setState(() {
      rows = [];
      queried = false;
      busy = false;
      error = null;
    });
  }

  Future<void> query() async {
    final seq = ++generation;
    setState(() {
      busy = true;
      error = null;
      rows = [];
      queried = false;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/external/screens/$queryID/query',
        body: {
          'station': station,
          'date': start.text.trim(),
          'from': mode == 'daily' ? start.text.trim() : '',
          'to': mode == 'daily' ? end.text.trim() : '',
          'mode': mode,
        },
      );
      if (mounted && seq == generation) {
        setState(() {
          applyLayout(data, 'screen_revision');
          rows = objects(data['statistics']);
          busy = false;
          queried = true;
        });
      }
    } catch (e) {
      if (mounted && seq == generation) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  String number(Object? v) => reportNumber(v, decimals);

  String text(Object? v) => v == null ? '—' : '$v';
  String time(Object? v) =>
      text(v).replaceAll('T', ' ').replaceAll('+08:00', '');
  bool get day => mode == 'daily';
  List<Json> get visibleColumns => layout.where((c) {
    final key = c['key'] as String;
    if (!widget.development &&
        (key.endsWith('_status') ||
            key.startsWith('sample_') ||
            const {
              'progress',
              'day_subtotal',
              'day_record',
              'valid_hours',
              'day_status_code',
              'day_anomaly',
            }.contains(key))) {
      return false;
    }
    if (energy && key.startsWith('hour')) return false;
    if (c['visible'] != true) return false;
    if (day && key.startsWith('hour')) return false;
    if (widget.screen['kind'] == 'daily' &&
        const {'day_min', 'day_max', 'sample_min'}.contains(key)) {
      return false;
    }
    if (mode == 'hourly' &&
        const {'day_usage', 'day_min', 'day_max'}.contains(key)) {
      return false;
    }
    if (energy &&
        const {'hour_min', 'hour_max', 'day_min', 'day_max'}.contains(key)) {
      return false;
    }
    return true;
  }).toList();
  String cell(Json r, String key, {bool exporting = false}) => switch (key) {
    'day_value' => dailyReading(
      r,
      exporting ? readableDecimal : number,
      diagnostics: widget.development,
    ),
    'station' => text(r['name']),
    'progress' => r['current_day'] == true ? '截至采样' : '自然日',
    'day_record' =>
      r[key] == null
          ? '—'
          : const {'true', '1'}.contains('${r[key]}')
          ? '有'
          : '无',
    'hour' || 'sample_min' || 'sample_max' => time(r[key]),
    'day_usage' when energy && !widget.development =>
      exporting
          ? text(r['day_usage'] ?? r['day_subtotal'])
          : number(r['day_usage'] ?? r['day_subtotal']),
    'hour_usage' ||
    'hour_min' ||
    'hour_max' ||
    'day_usage' ||
    'day_min' ||
    'day_max' ||
    'day_subtotal' => exporting ? text(r[key]) : number(r[key]),
    _ => text(r[key]),
  };
  Widget field(String label, TextEditingController c) => SizedBox(
    width: 160,
    child: DateTimeField(
      controller: c,
      label: label,
      onChanged: (_) => changed(),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final chartRows = rows.where((r) => r['metric'] == metric).toList();
    final grid = StatisticsGrid(
      records: rows,
      columns: visibleColumns,
      energy: energy,
      mode: periodReport ? 'daily' : mode,
      format: cell,
      includeEmptyMetrics: widget.development,
    );
    final canQuery =
        !loading &&
        !busy &&
        stations.isNotEmpty &&
        (!(mode == 'hourly' || mode == 'zones') || station.isNotEmpty);
    return QueryControlTheme(
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 650;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: QueryToolbar(
                  key: const Key('statistics-query-toolbar'),
                  maxHeight: box.maxHeight * .58,
                  fields: [
                    SizedBox(
                      width: narrow ? 220 : 250,
                      child: DropdownButtonFormField<String>(
                        isDense: true,
                        key: ValueKey('station-$station'),
                        initialValue: station,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: energy ? '整站' : '站区',
                        ),
                        items: [
                          if (energy)
                            const DropdownMenuItem(
                              value: '',
                              child: Text('全部整站'),
                            ),
                          for (final s in stations)
                            DropdownMenuItem(
                              value: s['code'] as String,
                              child: Text(
                                '${s['name']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: loading
                            ? null
                            : (v) {
                                station = v!;
                                changed();
                              },
                      ),
                    ),
                    if (energy)
                      SizedBox(
                        width: 160,
                        child: DropdownButtonFormField<String>(
                          isDense: true,
                          initialValue: mode,
                          decoration: const InputDecoration(labelText: '查询方式'),
                          items: [
                            const DropdownMenuItem(
                              value: 'current',
                              child: Text('当前总览'),
                            ),
                            const DropdownMenuItem(
                              value: 'daily',
                              child: Text('历史日用量'),
                            ),
                            if (widget.development)
                              const DropdownMenuItem(
                                value: 'zones',
                                child: Text('站区核数'),
                              ),
                          ],
                          onChanged: (v) {
                            mode = v!;
                            if ((mode == 'hourly' || mode == 'zones') &&
                                station.isEmpty) {
                              station =
                                  stations.firstOrNull?['code'] as String? ??
                                  '';
                            }
                            changed();
                          },
                        ),
                      ),
                    if (mode != 'current')
                      field(
                        day
                            ? '开始日期（含）'
                            : mode == 'monthly'
                            ? '月份（选择任一天）'
                            : mode == 'season'
                            ? '采暖季（选择季内日期）'
                            : '日期',
                        start,
                      ),
                    if (day) field('结束日期（含）', end),
                    if (error != null && stations.isEmpty)
                      TextButton(onPressed: load, child: const Text('重试站点目录')),
                    SizedBox(
                      width: 105,
                      child: DropdownButtonFormField<int>(
                        isDense: true,
                        initialValue: decimals,
                        decoration: const InputDecoration(labelText: '小数位'),
                        items: [
                          for (var i = 0; i <= 6; i++)
                            DropdownMenuItem(value: i, child: Text('$i')),
                        ],
                        onChanged: (v) => setState(() => decimals = v!),
                      ),
                    ),
                  ],
                  actions: [
                    FilledButton.icon(
                      onPressed: canQuery ? query : null,
                      icon: const Icon(Icons.search),
                      label: Text(busy ? '查询中…' : '查询'),
                    ),
                    ...widget.actions,
                  ],
                ),
              ),
              if (loading || busy) const LinearProgressIndicator(minHeight: 2),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (layoutError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: TextButton(
                    onPressed: refreshLayout,
                    child: Text(layoutError!),
                  ),
                ),
              if (energy &&
                  mode == 'hourly' &&
                  rows.isNotEmpty &&
                  box.maxHeight > 500) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DropdownButton<String>(
                    value: metric,
                    items: const [
                      DropdownMenuItem(
                        value: 'electricity',
                        child: Text('电 · kWh'),
                      ),
                      DropdownMenuItem(value: 'water', child: Text('水 · t')),
                      DropdownMenuItem(value: 'heat', child: Text('热 · GJ')),
                    ],
                    onChanged: (v) => setState(() => metric = v!),
                  ),
                ),
                SizedBox(
                  height: narrow ? 150 : 210,
                  child: Trend(
                    rows: [
                      for (final r in chartRows)
                        {
                          'point_id': metric,
                          'source_time': r['hour'],
                          'value': double.tryParse('${r['hour_usage']}') ?? 0,
                          'quality': r['hour_usage'] == null ? 'bad' : 'good',
                        },
                    ],
                    names: {
                      metric: rows.any((r) => r['current_day'] == true)
                          ? '小时用量（当前小时）'
                          : '小时用量',
                    },
                  ),
                ),
              ],
              if (widget.development && widget.screen['kind'] == 'daily')
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text('当天显示截至最新统计的用量或范围；无数据为 —。'),
                ),
              if (rows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('导出当前结果'),
                      onPressed: () async {
                        final csv = TableCsv(
                          styles: ReportStyleScope.of(context)?.styles,
                          sourceHeaders: grid.headers,
                          headerGroups: grid.headerGroups,
                          headerGroupKeys: grid.headerGroupKeys,
                        )..add(grid.exportHeaders);
                        for (var i = 0; i < grid.rows.length; i++) {
                          csv.add(grid.cells(i, exporting: true));
                        }
                        try {
                          final saved = await csv.save(
                            '${energy ? '能耗查询' : '统计报表'}.csv',
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(saved ? '导出已完成' : '已取消导出'),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
                          }
                        }
                      },
                    ),
                  ),
                ),
              Expanded(
                child: DenseTable(
                  reportStyle: true,
                  key: ValueKey(
                    '$mode-$energy-${grid.exportHeaders.join('|')}',
                  ),
                  headers: grid.headers,
                  headerGroups: grid.headerGroups,
                  headerGroupKeys: grid.headerGroupKeys,
                  initialWidths: grid.widths,
                  numericColumns: grid.numericColumns,
                  rowCount: grid.rows.length,
                  rowBuilder: (i) => grid.cells(i),
                  emptyLabel: queried ? '查询无统计记录' : '选择条件后查询',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
