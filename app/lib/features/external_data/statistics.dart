import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';
import '../trend.dart';
import 'catalog.dart';
import 'statistics_columns.dart';
import 'statistics_grid.dart';
import 'comparison.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/date_time_field.dart';

class EnergyWorkspace extends StatefulWidget {
  const EnergyWorkspace({super.key, required this.catalog});
  final ExternalCatalog catalog;
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
      final screens = c.screens
          .where((s) => const {'energy', 'comparison'}.contains(s['kind']))
          .toList();
      final screen =
          screens.where((s) => s['id'] == selected).firstOrNull ??
          screens.firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.bolt_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: screens.length > 1
                      ? DropdownButton<String>(
                          isExpanded: true,
                          value: screen?['id'] as String?,
                          items: [
                            for (final s in screens)
                              DropdownMenuItem(
                                value: s['id'] as String,
                                child: Text('${s['name']}'),
                              ),
                          ],
                          onChanged: (v) => setState(() => selected = v),
                        )
                      : Text(
                          '${screen?['name'] ?? '能耗管理'}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                ),
                IconButton(
                  tooltip: '刷新能耗目录',
                  onPressed: c.loading ? null : c.load,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (c.loading) const LinearProgressIndicator(),
          if (c.error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(c.error!)),
          Expanded(
            child: screen == null
                ? const Center(
                    child: Text(
                      '暂无已授权的能耗画面。\n请在开发端外数据中添加“能耗管理”，选择现有数据源并授权。',
                      textAlign: TextAlign.center,
                    ),
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
  bool settlementDetails = false;
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
    layout = statisticsLayout({...data, 'kind': widget.screen['kind']});
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
      ).where((s) => s['id'] == widget.screen['id']).firstOrNull;
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
        '/api/v1/external/screens/${widget.screen['id']}/stations',
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
        '/api/v1/external/screens/${widget.screen['id']}/query',
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

  String number(Object? v) {
    if (v == null) return '—';
    final text = '$v';
    final n = double.tryParse(text);
    if (n == null || !n.isFinite) {
      return text; // Preserve large decimal precision in tables.
    }
    if (text.replaceAll(RegExp(r'[^0-9]'), '').length > 15) return text;
    return n.toStringAsFixed(decimals);
  }

  String text(Object? v) => v == null ? '—' : '$v';
  String time(Object? v) =>
      text(v).replaceAll('T', ' ').replaceAll('+08:00', '');
  bool get day => mode == 'daily';
  List<Json> get visibleColumns => layout.where((c) {
    final key = c['key'] as String;
    if (energy && key.startsWith('hour')) return false;
    if (settlementDetails &&
        const {
          'day_subtotal',
          'day_status',
          'valid_hours',
          'day_record',
          'day_status_code',
          'day_anomaly',
        }.contains(key)) {
      return true;
    }
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
    if (energy && mode != 'zones' && key == 'day_subtotal') return false;
    return true;
  }).toList();
  String cell(Json r, String key, {bool exporting = false}) => switch (key) {
    'station' => text(r['name']),
    'progress' => r['current_day'] == true ? '截至采样' : '自然日',
    'day_record' =>
      r[key] == null
          ? '—'
          : const {'true', '1'}.contains('${r[key]}')
          ? '有'
          : '无',
    'hour' || 'sample_min' || 'sample_max' => time(r[key]),
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
      mode: mode,
      format: cell,
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
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: box.maxHeight * .48),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
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
                              decoration: const InputDecoration(
                                labelText: '查询方式',
                              ),
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
                                      stations.firstOrNull?['code']
                                          as String? ??
                                      '';
                                }
                                changed();
                              },
                            ),
                          ),
                        if (mode != 'current')
                          field(day ? '开始日期（含）' : '日期', start),
                        if (day) field('结束日期（含）', end),
                        FilledButton.icon(
                          onPressed: canQuery ? query : null,
                          icon: const Icon(Icons.search),
                          label: Text(busy ? '查询中…' : '查询'),
                        ),
                        if (error != null && stations.isEmpty)
                          TextButton(
                            onPressed: load,
                            child: const Text('重试站点目录'),
                          ),
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
                        ...widget.actions,
                      ],
                    ),
                  ),
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
              if (widget.screen['kind'] == 'daily')
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: FilterChip(
                      label: const Text('结算与缺数详情'),
                      selected: settlementDetails,
                      onSelected: (v) => setState(() => settlementDetails = v),
                    ),
                  ),
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
                        final csv = TableCsv()..add(grid.exportHeaders);
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
