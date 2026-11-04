import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';

const comparisonDetailColumns = [
  '站点',
  '往年站名',
  '指标',
  '本期日期',
  '历史日期',
  '本期单位',
  '本期日用量',
  '历史日用量折算',
  '差值',
  '变化百分比',
  '对比状态',
  '本期状态',
  '历史状态',
  '本期最晚参与采样时间',
  '可比',
  '双方完整日有效',
];
const comparisonSummaryColumns = [
  '站点',
  '往年站名',
  '指标',
  '本期单位',
  '本期配对用量',
  '历史配对用量',
  '差值',
  '变化百分比',
  '选择天数',
  '参与对比天数',
  '排除天数',
  '本期完整有效天数',
  '历史有效天数',
  '双方完整日有效天数',
  '历史含异常天数',
  '汇总状态',
];

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
  static String date(DateTime d) => d.toIso8601String().substring(0, 10);
  final today = DateTime.now().toUtc().add(const Duration(hours: 8));
  late final start = TextEditingController(text: date(today));
  late final end = TextEditingController(text: date(today));
  late final historyStart = TextEditingController(
    text: date(DateTime(today.year - 1, today.month, today.day)),
  );
  late final historyEnd = TextEditingController(text: historyStart.text);
  final factor = TextEditingController();
  List<Json> stations = [], rows = [];
  String station = '', metric = '', resultType = '明细';
  String? error;
  bool loading = true, busy = false, queried = false, sources = false;
  int generation = 0;
  String get path => '/api/v1/external/screens/${widget.screen['id']}';
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    generation++;
    for (final c in [start, end, historyStart, historyEnd, factor]) {
      c.dispose();
    }
    super.dispose();
  }

  void changed() {
    generation++;
    setState(() {
      rows = [];
      error = null;
      busy = false;
      queried = false;
    });
  }

  Future<void> load() async {
    try {
      final data = await widget.api.request('GET', '$path/stations');
      if (!mounted) return;
      setState(() {
        stations = objects(data['items']);
        loading = false;
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
    if (busy || loading) return;
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = null;
      rows = [];
      queried = false;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '$path/query',
        body: {
          'station': station,
          'from': start.text.trim(),
          'to': end.text.trim(),
          'history_from': historyStart.text.trim(),
          'history_to': historyEnd.text.trim(),
          'metric': metric,
          'comparison_type': resultType,
          'history_factor': factor.text.trim(),
        },
      );
      if (!mounted || ticket != generation) return;
      setState(() {
        rows = objects(data['comparisons']);
        queried = true;
      });
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  void shift(TextEditingController a, TextEditingController b, int days) {
    final x = DateTime.tryParse(a.text), y = DateTime.tryParse(b.text);
    if (x == null || y == null) return;
    a.text = date(x.add(Duration(days: days)));
    b.text = date(y.add(Duration(days: days)));
    changed();
  }

  Widget input(String label, TextEditingController c, {double width = 155}) =>
      SizedBox(
        width: width,
        child: TextField(
          controller: c,
          onChanged: (_) => changed(),
          decoration: InputDecoration(
            labelText: label,
            hintText: c == factor ? '默认原值 / 登记系数' : 'YYYY-MM-DD',
          ),
        ),
      );
  Widget dates(
    String label,
    TextEditingController a,
    TextEditingController b,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      input('$label开始', a),
      input('$label结束', b),
      IconButton(
        tooltip: '$label窗口前移一天',
        onPressed: () => shift(a, b, -1),
        icon: const Icon(Icons.chevron_left),
      ),
      IconButton(
        tooltip: '$label窗口后移一天',
        onPressed: () => shift(a, b, 1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  List<String> get columns => [
    ...(resultType == '明细'
        ? comparisonDetailColumns
        : comparisonSummaryColumns),
    if (sources && resultType == '明细') ...['历史日用量', '历史单位', '历史取数方式', '历史参与列'],
    if (resultType == '汇总') ...['本期开始日期', '本期结束日期', '历史开始日期', '历史结束日期'],
  ];
  String cell(Json row, String key, {bool export = false}) {
    if (key == '站点') {
      for (final item in stations) {
        if (item['code'] == row['整站编码']) return '${item['name']}';
      }
      return '站名待维护';
    }
    if (key == '往年站名') return '${row['甲方站名'] ?? '—'}';
    final v = row[key];
    if (v == null) return '—';
    final text = '$v';
    if (key == '变化百分比') return '$text%';
    if (key.endsWith('日期')) return text.split('T').first;
    if (key.contains('采样时间')) {
      return text.replaceAll('T', ' ').replaceAll('+08:00', '');
    }
    if (const {'可比', '双方完整日有效'}.contains(key)) {
      return const {'1', 'true'}.contains(text) ? '是' : '否';
    }
    return text;
  }

  Future<void> export() async {
    final csv = TableCsv()..add(columns);
    for (final r in rows) {
      csv.add([for (final c in columns) cell(r, c, export: true)]);
    }
    try {
      final saved = await csv.save('同期对比-$resultType.csv');
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

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          flex: 0,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .52,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${widget.screen['name']}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        ...widget.actions,
                        SizedBox(
                          width: 205,
                          child: DropdownButtonFormField<String>(
                            initialValue: station,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: '整站'),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('全部站点'),
                              ),
                              for (final s in stations)
                                DropdownMenuItem(
                                  value: s['code'] as String,
                                  child: Text('${s['name']}'),
                                ),
                            ],
                            onChanged: (v) {
                              station = v ?? '';
                              changed();
                            },
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: DropdownButtonFormField<String>(
                            initialValue: metric,
                            decoration: const InputDecoration(labelText: '指标'),
                            items: [
                              for (final m in const ['', '水', '电', '热'])
                                DropdownMenuItem(
                                  value: m,
                                  child: Text(m.isEmpty ? '水电热' : m),
                                ),
                            ],
                            onChanged: (v) {
                              metric = v ?? '';
                              changed();
                            },
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: DropdownButtonFormField<String>(
                            initialValue: resultType,
                            decoration: const InputDecoration(labelText: '结果'),
                            items: [
                              for (final t in const ['明细', '汇总'])
                                DropdownMenuItem(value: t, child: Text(t)),
                            ],
                            onChanged: (v) {
                              resultType = v!;
                              changed();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    dates('本期', start, end),
                    const SizedBox(height: 10),
                    dates('历史', historyStart, historyEnd),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        input('历史换算系数（可选）', factor, width: 205),
                        FilledButton.icon(
                          onPressed: loading || busy || stations.isEmpty
                              ? null
                              : query,
                          icon: const Icon(Icons.search),
                          label: Text(busy ? '查询中…' : '查询对比'),
                        ),
                        OutlinedButton.icon(
                          onPressed: rows.isEmpty ? null : export,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('导出当前结果'),
                        ),
                        if (resultType == '明细')
                          FilterChip(
                            label: const Text('取数来源'),
                            selected: sources,
                            onSelected: (v) => setState(() => sources = v),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '本期从2026-11-04开始；两段窗口含首尾且天数相同，最多366天。箭头平移对应窗口一天。当天显示截至值；缺数与新站无历史保留，汇总仅比较双方有效的同一组日期。',
                    ),
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
        ),
        if (loading || busy) const LinearProgressIndicator(),
        Expanded(
          child: DenseTable(
            key: ValueKey('$resultType-$sources'),
            headers: columns,
            initialWidths: [
              for (final c in columns)
                c.contains('状态') || c.contains('时间') ? 180 : 130,
            ],
            rowCount: rows.length,
            rowBuilder: (i) => [for (final c in columns) cell(rows[i], c)],
            emptyLabel: queried ? '此窗口暂无结果' : '设置日期窗口后查询同期对比',
          ),
        ),
      ],
    ),
  );
}
