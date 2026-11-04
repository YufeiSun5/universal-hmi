import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/date_time_field.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/table_csv.dart';
import 'comparison_charts.dart';

const comparisonSummaryColumns = [
  '站点',
  '指标',
  '单位',
  '本期有效用量小计',
  '历史有效用量小计',
  '本期配对用量',
  '历史配对用量',
  '用量差值',
  '用量变化百分比',
  '用量状态',
  '选择秒数',
  '用量可比秒数',
  '本期配对平均气温',
  '历史配对平均气温',
  '气温可比秒数',
  '气温状态',
  '本期开始时间',
  '本期结束时间',
  '历史开始时间',
  '历史结束时间',
];
const comparisonDetailColumns = [
  '站点',
  '指标',
  '单位',
  '本期开始',
  '本期结束',
  '历史开始',
  '历史结束',
  '片段秒数',
  '本期用量',
  '历史折算用量',
  '用量差值',
  '用量变化百分比',
  '本期状态',
  '历史状态',
  '本期平均气温',
  '历史整点气温',
  '气温可比',
  '本期成员最早截止',
  '本期成员最晚截止',
  '历史取数说明',
];
double? comparisonNumber(dynamic v) => v == null ? null : double.tryParse('$v');
String comparisonValue(dynamic v, {String unit = ''}) {
  final n = comparisonNumber(v);
  return n == null ? '—' : '${n.toStringAsFixed(2)}$unit';
}

String comparisonTime(dynamic v) =>
    v == null ? '—' : '$v'.replaceAll('T', ' ').replaceAll('+08:00', '');

class ComparisonQuery extends StatefulWidget {
  const ComparisonQuery({
    super.key,
    required this.api,
    required this.screen,
    this.actions = const [],
    this.autoQuery = true,
  });
  final PlatformApi api;
  final Json screen;
  final List<Widget> actions;
  final bool autoQuery;
  @override
  State<ComparisonQuery> createState() => _ComparisonQueryState();
}

class _ComparisonQueryState extends State<ComparisonQuery> {
  final now = beijingNow();
  late final start = TextEditingController(text: '${beijingText(now)}T00:00');
  late final end = TextEditingController(text: beijingText(now, time: true));
  late final historyStart = TextEditingController(
    text: '${beijingText(DateTime(now.year - 1, now.month, now.day))}T00:00',
  );
  final factors = [
    for (var i = 0; i < 3; i++) TextEditingController(text: '1'),
  ];
  List<Json> stations = [], rows = [], detail = [], days = [];
  String station = '', chartStation = '';
  String? error, detailError;
  bool loading = true,
      busy = false,
      detailBusy = false,
      untilNow = true,
      daily = false,
      showFactors = false;
  int generation = 0, detailGeneration = 0;
  Json? snapshot;
  Timer? debounce;
  String get path => '/api/v1/external/screens/${widget.screen['id']}';
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    generation++;
    detailGeneration++;
    debounce?.cancel();
    for (final c in [start, end, historyStart, ...factors]) {
      c.dispose();
    }
    super.dispose();
  }

  String name(String code) =>
      '${stations.where((s) => s['code'] == code).firstOrNull?['name'] ?? '站名待维护'}';
  String get historicalEnd {
    final a = beijingWall(start.text),
        h = beijingWall(historyStart.text),
        b = untilNow ? beijingNow() : beijingWall(end.text);
    return a == null || b == null || h == null
        ? '待选择'
        : beijingText(h.add(b.difference(a)), time: true).replaceAll('T', ' ');
  }

  void changed({bool repeat = false}) {
    final had = snapshot != null || busy || (debounce?.isActive ?? false);
    generation++;
    detailGeneration++;
    debounce?.cancel();
    setState(() {
      rows = [];
      detail = [];
      days = [];
      snapshot = null;
      chartStation = '';
      error = null;
      detailError = null;
      busy = false;
      detailBusy = false;
    });
    if (repeat && had) {
      debounce = Timer(const Duration(milliseconds: 350), query);
    }
  }

  Future<void> load() async {
    try {
      final data = await widget.api.request('GET', '$path/stations');
      if (!mounted) return;
      setState(() {
        stations = objects(data['items']);
        loading = false;
        station = '${stations.firstOrNull?['code'] ?? ''}';
      });
      if (widget.autoQuery && stations.isNotEmpty) await query();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> query() async {
    debounce?.cancel();
    if (loading) return;
    final ticket = ++generation;
    detailGeneration++;
    final request = <String, dynamic>{
      'mode': 'sliding',
      'station': station,
      'from': beijingIso(start.text),
      'to': untilNow ? '' : beijingIso(end.text),
      'history_from': beijingIso(historyStart.text),
      'comparison_type': '汇总',
      'water_factor': factors[0].text.trim(),
      'electricity_factor': factors[1].text.trim(),
      'heat_factor': factors[2].text.trim(),
    };
    setState(() {
      busy = true;
      error = null;
      rows = [];
      snapshot = null;
      detail = [];
      days = [];
      chartStation = '';
      detailBusy = false;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '$path/query',
        body: request,
      );
      if (!mounted || ticket != generation) return;
      setState(() {
        rows = objects(data['comparisons']);
        final first = rows.firstOrNull;
        snapshot = {
          ...request,
          if (first != null) ...{
            'from': first['本期开始时间'],
            'to': first['本期结束时间'],
            'history_from': first['历史开始时间'],
            'history_to': first['历史结束时间'],
          },
        };
      });
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> curves(String code) async {
    if (snapshot == null) return;
    final ticket = ++detailGeneration, parent = generation;
    setState(() {
      chartStation = code;
      detail = [];
      days = [];
      detailBusy = true;
      detailError = null;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '$path/query',
        body: {...snapshot!, 'station': code, 'comparison_type': '明细'},
      );
      if (!mounted || ticket != detailGeneration || parent != generation) {
        return;
      }
      setState(() {
        detail = objects(data['comparisons']);
        days = objects(data['comparison_days']);
      });
    } catch (e) {
      if (mounted && ticket == detailGeneration && parent == generation) {
        setState(() => detailError = '$e');
      }
    } finally {
      if (mounted && ticket == detailGeneration && parent == generation) {
        setState(() => detailBusy = false);
      }
    }
  }

  void shift(bool history, int direction) {
    final duration = Duration(hours: direction * (daily ? 24 : 1));
    if (history) {
      final h = beijingWall(historyStart.text);
      if (h == null) return;
      historyStart.text = beijingStamp(h.add(duration));
    } else {
      final a = beijingWall(start.text),
          b = untilNow
              ? (snapshot?['to'] == null
                    ? beijingNow()
                    : beijingWall('${snapshot!['to']}'))
              : beijingWall(end.text);
      if (a == null || b == null) return;
      start.text = beijingStamp(a.add(duration));
      end.text = beijingStamp(b.add(duration));
      untilNow = false;
    }
    changed(repeat: true);
  }

  void align() {
    final a = beijingWall(start.text);
    if (a == null) return;
    final last = DateTime(a.year - 1, a.month + 1, 0).day;
    historyStart.text = beijingStamp(
      DateTime.utc(
        a.year - 1,
        a.month,
        a.day > last ? last : a.day,
        a.hour,
        a.minute,
        a.second,
        a.millisecond,
      ),
    );
    changed(repeat: true);
  }

  Future<void> export(bool fragments) async {
    final columns = fragments
        ? comparisonDetailColumns
        : comparisonSummaryColumns;
    final csv = TableCsv()..add(columns);
    for (final r in fragments ? detail : rows) {
      csv.add([
        for (final c in columns)
          c == '站点'
              ? name('${r['整站编码']}')
              : r[c] == null
              ? '—'
              : '${r[c]}',
      ]);
    }
    try {
      final saved = await csv.save(
        '同期对比-${fragments ? '小时明细' : '汇总'}-UTC+8.csv',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(saved ? '导出已完成' : '已取消导出')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Widget dateField(
    String label,
    TextEditingController c, {
    bool enabled = true,
  }) => SizedBox(
    width: 215,
    child: DateTimeField(
      controller: c,
      label: label,
      includeTime: true,
      enabled: enabled,
      onChanged: (_) => changed(),
    ),
  );
  Widget moves(String label, bool history) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: '$label窗口前移${daily ? '一天' : '一小时'}',
        onPressed: () => shift(history, -1),
        icon: const Icon(Icons.chevron_left),
      ),
      IconButton(
        tooltip: '$label窗口后移${daily ? '一天' : '一小时'}',
        onPressed: () => shift(history, 1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  Widget metricCard(Json row, double width) {
    final unit = '${row['单位'] ?? ''}', delta = comparisonNumber(row['用量差值']);
    final selected = comparisonNumber(row['选择秒数']) ?? 0,
        paired = comparisonNumber(row['用量可比秒数']) ?? 0;
    String subtotal(String side) =>
        '${comparisonValue(row['$side有效用量小计'])} $unit${(comparisonNumber(row['$side有效秒数']) ?? 0) < selected ? ' · 部分有效小计' : ''}';
    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: .3),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row['指标']} · $unit',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '本期 ${comparisonValue(row['本期配对用量'])}  /  历史 ${comparisonValue(row['历史配对用量'])}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            delta == null
                ? '暂无可比用量'
                : '${delta <= 0 ? '本期少用' : '本期多用'} ${delta.abs().toStringAsFixed(2)} $unit · 用量变化 ${comparisonValue(row['用量变化百分比'], unit: '%')}',
          ),
          Text(
            '${row['用量状态'] ?? '—'} · 配对覆盖 ${selected <= 0 ? '—' : (paired / selected * 100).toStringAsFixed(1)}%',
          ),
          const Divider(height: 18),
          Text('本期独立小计 ${subtotal('本期')}'),
          Text('历史独立小计 ${subtotal('历史')}'),
        ],
      ),
    );
  }

  Widget stationResult(String code) {
    final group = rows.where((r) => r['整站编码'] == code).toList(),
        first = rows.firstWhere((r) => r['整站编码'] == code);
    final seconds = comparisonNumber(first['选择秒数']) ?? 0,
        temperatureSeconds = comparisonNumber(first['气温可比秒数']) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                name(code),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextButton.icon(
                onPressed: detailBusy ? null : () => curves(code),
                icon: const Icon(Icons.show_chart),
                label: Text(chartStation == code ? '刷新曲线' : '展开曲线'),
              ),
            ],
          ),
          Text(
            '配对气温  本期 ${comparisonValue(first['本期配对平均气温'], unit: '℃')}  /  历史 ${comparisonValue(first['历史配对平均气温'], unit: '℃')} · ${first['气温状态'] ?? '—'} · 缺失覆盖 ${((seconds - temperatureSeconds).clamp(0, double.infinity) / 3600).toStringAsFixed(2)} 小时',
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, box) {
              final width = box.maxWidth >= 900
                  ? (box.maxWidth - 16) / 3
                  : box.maxWidth;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final metric in ['热', '电', '水'])
                    for (final row in group.where((r) => r['指标'] == metric))
                      metricCard(row, width),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Text('${first['气温说明'] ?? '本期为现场采样；历史为再分析气温，非历史站内实测。'}'),
          if (chartStation == code) ...[
            if (detailBusy) const LinearProgressIndicator(),
            if (detailError != null)
              Text(
                detailError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (detail.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () => export(true),
                icon: const Icon(Icons.download_outlined),
                label: const Text('导出小时明细'),
              ),
              ComparisonCharts(
                key: ValueKey('$code-$generation-$daily'),
                rows: daily ? days : detail,
                daily: daily,
              ),
              const Text('日期曲线按所选日内片段汇总；缺失片段保持断点。气温按时长加权，缺失不补零。'),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .48,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${widget.screen['name']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      ...widget.actions,
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(station),
                          initialValue: station,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '站点'),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('全部站点'),
                            ),
                            for (final s in stations)
                              DropdownMenuItem(
                                value: '${s['code']}',
                                child: Text(
                                  '${s['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            station = v ?? '';
                            changed();
                          },
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: loading || busy || stations.isEmpty
                            ? null
                            : query,
                        icon: const Icon(Icons.search),
                        label: Text(busy ? '查询中…' : '查询对比'),
                      ),
                      OutlinedButton.icon(
                        onPressed: rows.isEmpty ? null : () => export(false),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('导出汇总'),
                      ),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('小时')),
                          ButtonSegment(value: true, label: Text('日期')),
                        ],
                        selected: {daily},
                        onSelectionChanged: (s) =>
                            setState(() => daily = s.single),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      dateField('本期开始', start),
                      dateField('本期结束（不含）', end, enabled: !untilNow),
                      FilterChip(
                        label: const Text('截至现在'),
                        selected: untilNow,
                        onSelected: (v) {
                          untilNow = v;
                          if (!v) {
                            end.text = beijingText(beijingNow(), time: true);
                          }
                          changed();
                        },
                      ),
                      moves('本期', false),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      dateField('历史开始', historyStart),
                      Text('等长结束：$historicalEnd'),
                      moves('历史', true),
                      TextButton.icon(
                        onPressed: align,
                        icon: const Icon(Icons.align_horizontal_left),
                        label: const Text('恢复同期对齐'),
                      ),
                      FilterChip(
                        label: const Text('换算系数'),
                        selected: showFactors,
                        onSelected: (v) => setState(() => showFactors = v),
                      ),
                    ],
                  ),
                  if (showFactors)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 12,
                        children: [
                          for (var i = 0; i < 3; i++)
                            SizedBox(
                              width: 155,
                              child: TextField(
                                controller: factors[i],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: (_) => changed(),
                                decoration: InputDecoration(
                                  labelText: '历史${['水', '电', '热'][i]}换算系数',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text('北京时间 UTC+8 · 默认同期对齐，可按小时或日期平移；历史结束自动保持等长。'),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (loading || busy) const LinearProgressIndicator(),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(snapshot != null ? '此窗口暂无结果' : '选择窗口后查询同期对比'),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Text(
                      '本期 ${comparisonTime(rows.first['本期开始时间'])} 至 ${comparisonTime(rows.first['本期结束时间'])}',
                    ),
                    Text(
                      '历史 ${comparisonTime(rows.first['历史开始时间'])} 至 ${comparisonTime(rows.first['历史结束时间'])}',
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('用量差异采用双方有效的同一组片段。全站结果分别展示，不相加为全网总耗热。'),
                    ),
                    for (final code in rows.map((r) => '${r['整站编码']}').toSet())
                      stationResult(code),
                    const Text(
                      '哪一年更省：以上是配对时段的实际用量变化。气温、供热面积和运行条件尚未归一化；建立并验证历史消耗基线前，不将变化率标为节能率。',
                    ),
                  ],
                ),
        ),
      ],
    ),
  );
}
