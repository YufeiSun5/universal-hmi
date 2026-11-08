import 'report_designer.dart';
import 'custom_report.dart';
import '../../shared/report_style.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/table_csv.dart';
import 'package:flutter/material.dart';
import '../../shared/date_time_field.dart';
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';
import '../../shared/table.dart';
import '../trend.dart';
import 'catalog.dart';
import 'alarm_columns.dart';
import 'reports.dart';
import 'sources.dart';
import 'statistics.dart';
import 'statistics_columns.dart';
import 'comparison.dart';
import 'history_columns.dart';

class ExternalWorkspace extends StatelessWidget {
  const ExternalWorkspace({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.screen,
    this.development = false,
    this.showPanel = false,
    this.autoQuery = false,
  });
  final ExternalCatalog catalog;
  final Json? screen;
  final bool development, showPanel, autoQuery;
  final ValueChanged<Json?> onOpen;
  @override
  Widget build(BuildContext context) => screen == null
      ? content(context)
      : ReportStyleHost(
          key: ValueKey(screen!['id']),
          screen: screen!,
          child: Builder(builder: content),
        );
  Widget content(BuildContext context) {
    final actions = screen != null && development && catalog.canDevelop
        ? [
            ReportStyleAction(
              catalog: catalog,
              screen: screen!,
              onSaved: onOpen,
            ),
            if (screen!['kind'] == 'standard')
              HistoryColumnAction(
                catalog: catalog,
                screen: screen!,
                onSaved: onOpen,
              ),
            if (const {'hourly', 'daily', 'energy'}.contains(screen!['kind']))
              StatisticsColumnAction(
                catalog: catalog,
                screen: screen!,
                onSaved: onOpen,
              ),
            if (screen!['kind'] == 'alarm')
              AlarmColumnAction(
                catalog: catalog,
                screen: screen!,
                onSaved: onOpen,
              ),
            IconButton(
              tooltip: '编辑画面名称',
              onPressed: () async {
                final s = await editExternalScreen(context, catalog, screen);
                if (s != null) onOpen(s);
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            IconButton(
              tooltip: '删除外数据画面',
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text('删除画面 ${screen!['name']}？'),
                    content: const Text('外部数据库及其历史数据不会被修改。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (yes != true) return;
                try {
                  await catalog.api.request(
                    'DELETE',
                    '/api/v1/external/screens/${screen!['id']}',
                    body: {'revision': screen!['revision']},
                  );
                  await catalog.load();
                  onOpen(null);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
          ]
        : const <Widget>[];
    final body = screen == null
        ? development && catalog.canDevelop
              ? ExternalSources(catalog: catalog, onOpen: onOpen)
              : const Center(child: Text('从左侧选择历史画面'))
        : screen!['kind'] == 'custom'
        ? CustomReportQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            actions: actions,
          )
        : screen!['kind'] == 'comparison'
        ? ComparisonQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            actions: actions,
            autoQuery: autoQuery,
          )
        : const {
            'hourly',
            'daily',
            'energy',
            'monthly',
            'season',
          }.contains(screen!['kind'])
        ? StatisticsQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            actions: actions,
            autoQuery: autoQuery,
            development: development && catalog.canDevelop,
          )
        : const {'standard', 'alarm'}.contains(screen!['kind'])
        ? ReportQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            autoQuery: autoQuery,
            actions: actions,
          )
        : ExternalQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            autoQuery: autoQuery,
            actions: actions,
          );
    return showPanel
        ? Material(
            color: Theme.of(context).colorScheme.surface,
            textStyle: Theme.of(context).textTheme.bodyMedium,
            child: Row(
              children: [
                SizedBox(
                  width: DesktopSidebar.width,
                  child: ExternalDataPanel(
                    catalog: catalog,
                    onOpen: onOpen,
                    selectedID: screen?['id'] as String?,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          )
        : body;
  }
}

class ExternalQuery extends StatefulWidget {
  const ExternalQuery({
    super.key,
    required this.api,
    required this.screen,
    this.actions = const [],
    this.autoQuery = false,
  });
  final PlatformApi api;
  final Json screen;
  final List<Widget> actions;
  final bool autoQuery;
  @override
  State<ExternalQuery> createState() => _ExternalQueryState();
}

class _ExternalQueryState extends State<ExternalQuery> {
  final shortScroll = ScrollController();
  late final date = TextEditingController(
    text: beijingNow().toIso8601String().substring(0, 10),
  );
  late final from = TextEditingController(text: '${date.text}T00:00');
  late final to = TextEditingController(
    text:
        '${beijingNow().add(const Duration(days: 1)).toIso8601String().substring(0, 10)}T00:00',
  );
  List<Json> stations = [];
  String station = '', columnFilter = '';
  String? error, stationError;
  Json? result;
  bool loading = true, busy = false, rangeOpen = false, showChart = true;
  int generation = 0, offset = 0, pointIndex = 0;
  bool get hourly => widget.screen['kind'] == 'hourly';
  bool get trend => widget.screen['kind'] == 'trend';
  @override
  void initState() {
    super.initState();
    loadStations();
  }

  @override
  void dispose() {
    generation++;
    shortScroll.dispose();
    date.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> loadStations() async {
    setState(() {
      loading = true;
      stationError = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/external/screens/${widget.screen['id']}/stations',
      );
      if (!mounted) return;
      setState(() {
        stations = objects(data['items']);
        station = stations.isEmpty ? '' : '${stations.first['code']}';
        loading = false;
      });
      if (widget.autoQuery && station.isNotEmpty) await query();
    } catch (e) {
      if (mounted) {
        setState(() {
          stationError = e.toString();
          loading = false;
        });
      }
    }
  }

  void changed() {
    generation++;
    setState(() {
      result = null;
      error = null;
      offset = 0;
      busy = false;
    });
  }

  Future<void> query([int nextOffset = 0]) async {
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/external/screens/${widget.screen['id']}/query',
        body: {
          'station': station,
          'date': date.text.trim(),
          'from': from.text.trim(),
          'to': to.text.trim(),
          'offset': nextOffset,
        },
      );
      if (!mounted || request != generation) return;
      setState(() {
        result = data;
        offset = nextOffset;
        pointIndex = 0;
        busy = false;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  String timeText(dynamic value) => value == null
      ? '—'
      : value
            .toString()
            .replaceFirst('T', ' ')
            .replaceFirst(RegExp(r'(Z|[+-]\d\d:\d\d)$'), '');
  String qualityText(Json r) => r['sample_time'] == null
      ? '缺测'
      : switch (r['quality']) {
          1 => '有效',
          2 => '有效 (2)',
          null => '未知质量',
          _ => '无效 (${r['quality']})',
        };
  Widget trendPointPicker(List<Json> points, {bool compact = false}) =>
      DropdownButtonFormField<int>(
        key: ValueKey('point-$pointIndex-${points.length}'),
        initialValue: pointIndex,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: compact ? '趋势测点（曲线仅当前页）' : '趋势测点',
          isDense: true,
        ),
        items: [
          for (var i = 0; i < points.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(
                '${points[i]['name']} (${points[i]['unit']})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => setState(() => pointIndex = v!),
      );

  String get stationLabel {
    for (final item in stations) {
      if ('${item['code']}' == station) return '${item['name']}';
    }
    return station;
  }

  Future<void> editRange() async {
    if (rangeOpen || busy || loading) return;
    rangeOpen = true;
    try {
      final selected =
          await showDialog<(String, TextEditingValue, TextEditingValue)>(
            context: context,
            builder: (_) => _ExternalTrendRange(
              stations: stations,
              station: station,
              from: from.value,
              to: to.value,
            ),
          );
      if (!mounted || selected == null) return;
      station = selected.$1;
      from.value = selected.$2;
      to.value = selected.$3;
      query();
    } finally {
      rangeOpen = false;
    }
  }

  Widget input(TextEditingController c, String label, double width) => SizedBox(
    width: width,
    child: DateTimeField(
      controller: c,
      label: label,
      includeTime: c != date,
      enabled: !busy,
      onChanged: (_) => changed(),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final points = objects(result?['points']), rows = objects(result?['rows']);
    final columns = [
      for (var i = 0; i < points.length; i++)
        if ('${points[i]['name']} ${points[i]['code']}'.toLowerCase().contains(
          columnFilter.toLowerCase(),
        ))
          i,
    ];
    final colors = Theme.of(context).colorScheme;
    final hasChart = trend && points.isNotEmpty && rows.isNotEmpty;
    final chart = hasChart
        ? Trend(
            key: ValueKey('${widget.screen['id']}-$offset-$pointIndex'),
            rows: [
              for (final r in rows)
                {
                  'point_id': '${points[pointIndex]['code']}',
                  'source_time': r['sample_time'] ?? r['target_time'],
                  // A bad marker is retained to break the existing chart path; it is never displayed as a value.
                  'value':
                      double.tryParse('${(r['values'] as List)[pointIndex]}') ??
                      0,
                  'quality':
                      (r['values'] as List)[pointIndex] != null &&
                          const [1, 2].contains(r['quality'])
                      ? 'good'
                      : 'bad',
                },
            ],
            names: {
              '${points[pointIndex]['code']}':
                  '${points[pointIndex]['name']} (${points[pointIndex]['unit']})',
            },
          )
        : const SizedBox();
    final headers = <String>[
      if (hourly) '目标时间',
      '实际采样时间',
      '质量',
      if (hourly) '匹配',
      for (final i in columns)
        '${points[i]['name']}${points[i]['unit'] == '' ? '' : ' (${points[i]['unit']})'}',
    ];
    List<String> rowCells(Json r) => [
      if (hourly) timeText(r['target_time']),
      timeText(r['sample_time']),
      qualityText(r),
      if (hourly)
        const {'exact': '整点', 'nearest': '最近', 'missing': '缺测'}[r['match']] ??
            '未知',
      for (final p in columns) (r['values'] as List)[p]?.toString() ?? '—',
    ];
    Future<void> exportRows() async {
      final displayed = result!;
      final token = ++generation;
      final request = {
        'station': station,
        'date': date.text.trim(),
        'from': from.text.trim(),
        'to': to.text.trim(),
      };
      setState(() {
        busy = true;
        error = null;
      });
      try {
        final csv = TableCsv(styles: ReportStyleScope.of(context)?.styles)
          ..add(headers);
        if (hourly) {
          for (final r in rows) {
            csv.add(rowCells(r));
          }
        } else {
          await collectReportPages(
            displayed: displayed,
            rowsKey: 'rows',
            fetch: (offset) => widget.api.request(
              'POST',
              '/api/v1/external/screens/${widget.screen['id']}/query',
              body: {...request, 'offset': offset},
            ),
            active: () => mounted && generation == token,
            add: (r) => csv.add(rowCells(r)),
          );
        }
        if (mounted && generation == token) {
          await csv.save('${widget.screen['name']}-$station.csv');
        }
      } catch (e) {
        if (mounted && generation == token) {
          setState(() => error = e.toString());
        }
      } finally {
        if (mounted && generation == token) setState(() => busy = false);
      }
    }

    final exportButton = IconButton(
      constraints: const BoxConstraints.tightFor(width: 40, height: 32),
      padding: EdgeInsets.zero,
      tooltip: '导出全部 CSV',
      onPressed: result == null || busy ? null : exportRows,
      icon: const Icon(Icons.download_outlined),
    );
    final table = DenseTable(
      reportStyle: true,
      key: ValueKey('${widget.screen['id']}-$offset-${columns.join(',')}'),
      headers: headers,
      rowCount: rows.length,
      rowBuilder: (i) => rowCells(rows[i]),
      numericColumns: {for (var i = hourly ? 4 : 2; i < headers.length; i++) i},
      initialWidths: [
        if (hourly) 174,
        190,
        95,
        if (hourly) 75,
        for (final _ in columns) 155,
      ],
      emptyLabel: '此时间范围没有历史采样',
    );
    return LayoutBuilder(
      builder: (context, box) {
        final compact = trend && box.maxHeight < 520;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 3, 8, 2),
                child: Row(
                  children: [
                    Icon(
                      externalIcon(widget.screen['kind'] as String?),
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '${widget.screen['name']}',
                        maxLines: compact ? 1 : null,
                        overflow: compact ? TextOverflow.ellipsis : null,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    exportButton,
                    ...widget.actions,
                  ],
                ),
              ),
            if (compact)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      key: const Key('external-trend-range'),
                      onPressed: busy || loading ? null : editRange,
                      icon: const Icon(Icons.filter_alt_outlined, size: 16),
                      label: const Text('查询条件'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message:
                            '${widget.screen['name']}\n$stationLabel · ${from.text} — ${to.text}',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${widget.screen['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '$stationLabel · ${from.text} — ${to.text}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: busy || loading || station.isEmpty
                          ? null
                          : () => query(),
                      child: const Text('查询'),
                    ),
                    if (busy)
                      TextButton(onPressed: changed, child: const Text('取消等待')),
                    exportButton,
                    ...widget.actions,
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: QueryToolbar(
                  key: const Key('external-query-toolbar'),
                  maxHeight: box.maxHeight * .5,
                  fields: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('$station-${stations.length}'),
                        initialValue: station.isEmpty ? null : station,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '外部站区',
                          isDense: true,
                        ),
                        items: stations
                            .map(
                              (s) => DropdownMenuItem(
                                value: '${s['code']}',
                                child: Text(
                                  '${s['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: busy || loading
                            ? null
                            : (v) {
                                station = v!;
                                changed();
                                if (widget.autoQuery && station.isNotEmpty) {
                                  query();
                                }
                              },
                      ),
                    ),
                    if (hourly)
                      input(date, '日期 YYYY-MM-DD', 160)
                    else ...[
                      input(from, '开始 YYYY-MM-DDTHH:mm', 200),
                      input(to, '结束（不含）', 200),
                    ],
                  ],
                  actions: [
                    FilledButton.icon(
                      onPressed: busy || loading || station.isEmpty
                          ? null
                          : () => query(),
                      icon: const Icon(Icons.search, size: 17),
                      label: const Text('查询'),
                    ),
                    if (busy)
                      TextButton(onPressed: changed, child: const Text('取消等待')),
                  ],
                ),
              ),
            if (loading || busy) const LinearProgressIndicator(minHeight: 2),
            if (stationError != null)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        stationError!,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: loadStations,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(error!, style: TextStyle(color: colors.error)),
              ),
            if (result != null) ...[
              if (compact)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: points.isNotEmpty && showChart
                            ? trendPointPicker(points, compact: true)
                            : const Text(
                                '当前页数据',
                                style: TextStyle(fontSize: 12),
                              ),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('曲线'),
                        selected: showChart,
                        onSelected: (_) => setState(() => showChart = true),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('数据'),
                        selected: !showChart,
                        onSelected: (_) => setState(() => showChart = false),
                      ),
                    ],
                  ),
                ),
              if (!compact)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: compact ? 2 : 6,
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (!compact)
                        Text(
                          '第 ${offset ~/ 500 + 1} 页 · ${rows.length} 条 · UTC${(result!['utc_offset_minutes'] as num) >= 0 ? '+' : ''}${(result!['utc_offset_minutes'] as num) / 60}',
                        ),
                      if (!compact)
                        Text(
                          hourly
                              ? '整点 ±30 分钟最近采样 · 等距取早'
                              : '最多 31 天 · 每页 500 条${trend ? ' · 曲线仅表示当前页' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      if (trend && points.isNotEmpty && (!compact || showChart))
                        SizedBox(width: 280, child: trendPointPicker(points)),
                      if (!trend)
                        SizedBox(
                          width: 210,
                          child: TextField(
                            onChanged: (v) => setState(() => columnFilter = v),
                            decoration: const InputDecoration(
                              hintText: '筛选测点列',
                              isDense: true,
                              prefixIcon: Icon(Icons.search, size: 16),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (compact && hasChart)
                Expanded(
                  child: IndexedStack(
                    index: showChart ? 0 : 1,
                    children: [chart, table],
                  ),
                )
              else ...[
                if (hasChart) Expanded(flex: 2, child: chart),
                Expanded(flex: 3, child: table),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        compact
                            ? '第 ${offset ~/ 500 + 1} 页 · ${rows.length} 条 · UTC${(result!['utc_offset_minutes'] as num) >= 0 ? '+' : ''}${(result!['utc_offset_minutes'] as num) / 60}\n按当前测点定义 · 无效/缺测 —'
                            : '按当前测点定义查询 · 无效/缺测显示 —',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    if (!hourly) ...[
                      TextButton(
                        onPressed: offset == 0 || busy
                            ? null
                            : () => query(offset - 500),
                        child: const Text('上一页'),
                      ),
                      TextButton(
                        onPressed: result!['has_more'] != true || busy
                            ? null
                            : () => query(offset + 500),
                        child: const Text('下一页'),
                      ),
                    ],
                  ],
                ),
              ),
            ] else
              Expanded(
                child: Center(
                  child: Text(
                    busy
                        ? '正在查询外部历史…'
                        : loading
                        ? '正在读取外部站区…'
                        : stationError != null || error != null
                        ? '未取得查询结果'
                        : stations.isEmpty
                        ? '数据源没有启用的站区'
                        : '选择站区与日期后查询',
                  ),
                ),
              ),
          ],
        );
        if (compact && box.maxHeight < 240) {
          return Scrollbar(
            controller: shortScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: shortScroll,
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(height: 360, child: content),
            ),
          );
        }
        return content;
      },
    );
  }
}

class _ExternalTrendRange extends StatefulWidget {
  const _ExternalTrendRange({
    required this.stations,
    required this.station,
    required this.from,
    required this.to,
  });
  final List<Json> stations;
  final String station;
  final TextEditingValue from, to;
  @override
  State<_ExternalTrendRange> createState() => _ExternalTrendRangeState();
}

class _ExternalTrendRangeState extends State<_ExternalTrendRange> {
  late String station = widget.station;
  late final from = TextEditingController.fromValue(widget.from);
  late final to = TextEditingController.fromValue(widget.to);
  bool closing = false;
  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  void close({bool apply = false}) {
    if (closing || ModalRoute.of(context)?.isCurrent != true) return;
    closing = true;
    Navigator.pop(context, apply ? (station, from.value, to.value) : null);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('趋势查询条件'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: station.isEmpty ? null : station,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '外部站区'),
              items: [
                for (final item in widget.stations)
                  DropdownMenuItem(
                    value: '${item['code']}',
                    child: Text(
                      '${item['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => station = value);
              },
            ),
            const SizedBox(height: 16),
            DateTimeField(
              key: const Key('external-range-from'),
              controller: from,
              label: '开始时间',
              includeTime: true,
            ),
            const SizedBox(height: 16),
            DateTimeField(
              key: const Key('external-range-to'),
              controller: to,
              label: '结束（不含）',
              includeTime: true,
            ),
            const SizedBox(height: 8),
            const Text(
              '最多 31 天 · 每页 500 条 · 曲线仅表示当前页',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: close, child: const Text('取消')),
      FilledButton(
        onPressed: station.isEmpty ? null : () => close(apply: true),
        child: const Text('应用并查询'),
      ),
    ],
  );
}
