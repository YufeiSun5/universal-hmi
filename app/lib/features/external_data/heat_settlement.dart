import '../../shared/report_style.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/date_time_field.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';
import 'heat_price_history.dart';

const settlementHeaders = ['统计周期', '站点', '热量（GJ）', '单价（元/GJ）', '金额（元）'];
String settlementNumber(dynamic value) {
  if (value == null) return '—';
  final text = '$value';
  return text.contains('.')
      ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : text;
}

List<List<String>> settlementCells(Json report) => [
  for (final row in objects(report['rows']))
    [
      '${row['period']}',
      '${row['name']}',
      settlementNumber(row['heat']),
      settlementNumber(row['unit_price']),
      row['amount']?.toString() ?? '—',
    ],
  [
    '合计',
    '',
    settlementNumber(report['total_heat']),
    '',
    report['total_amount']?.toString() ?? '—',
  ],
];

class HeatSettlementQuery extends StatefulWidget {
  const HeatSettlementQuery({
    super.key,
    required this.api,
    required this.screen,
  });
  final PlatformApi api;
  final Json screen;
  @override
  State<HeatSettlementQuery> createState() => _HeatSettlementQueryState();
}

class _HeatSettlementQueryState extends State<HeatSettlementQuery> {
  final date = TextEditingController(text: beijingText(beijingNow()));
  late final end = TextEditingController(text: date.text);
  String mode = 'daily';
  String? error, storageError;
  bool loading = true, busy = false, pricesLoading = false;
  int generation = 0;
  Json prices = {'revision': 0, 'items': <Json>[]};
  Json? report;
  Timer? refresh;
  String get pricePath =>
      '/api/v1/external/screens/${widget.screen['query_id']}/heat-prices';
  @override
  void initState() {
    super.initState();
    loadPrices();
    refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!busy) loadPrices();
    });
  }

  Future<void> loadPrices() async {
    if (pricesLoading) return;
    pricesLoading = true;
    try {
      final next = await widget.api.request('GET', pricePath);
      if (!mounted) return;
      if (next['revision'] != prices['revision'] && report != null) {
        generation++;
        report = null;
        error = '共享价格已更新，请重新生成报表';
      }
      setState(() {
        prices = next;
        storageError = null;
      });
    } catch (e) {
      if (mounted) setState(() => storageError = '价格读取失败：$e');
    } finally {
      pricesLoading = false;
      if (mounted) setState(() => loading = false);
    }
  }

  int get selectedYear {
    final d = DateTime.tryParse(date.text.trim()) ?? beijingNow();
    return d.month > 11 || d.month == 11 && d.day >= 5 ? d.year : d.year - 1;
  }

  String get priceLabel {
    final row = objects(
      prices['items'],
    ).where((p) => p['year'] == selectedYear).firstOrNull;
    return '$selectedYear–${selectedYear + 1}：${row == null ? '未设置单价' : '${settlementNumber(row['unit_price'])} 元/GJ'}';
  }

  Future<void> history() async {
    await loadPrices();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => HeatPriceHistory(
        api: widget.api,
        path: pricePath,
        initial: prices,
        year: selectedYear,
        onChanged: (next) {
          if (!mounted) return;
          setState(() {
            prices = next;
            storageError = null;
          });
          changed();
        },
      ),
    );
  }

  void changed() => setState(() {
    generation++;
    busy = false;
    report = null;
    error = null;
  });
  Future<void> query() async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = null;
      report = null;
    });
    final input = <String, dynamic>{
      'mode': 'settlement_$mode',
      'date': date.text.trim(),
      if (mode == 'daily') ...{'from': date.text.trim(), 'to': end.text.trim()},
    };
    try {
      final response = await widget.api.request(
        'POST',
        '/api/v1/external/screens/${widget.screen['query_id']}/query',
        body: input,
      );
      if (!mounted || ticket != generation) return;
      final result = response['heat_settlement'];
      if (result is! Map) throw StateError('服务器尚未支持热量结算，请更新服务器');
      setState(() => report = Map<String, dynamic>.from(result));
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    }
    if (mounted && ticket == generation) setState(() => busy = false);
  }

  Future<void> export() async {
    final snapshot = report;
    if (snapshot == null) return;
    final csv = TableCsv(styles: ReportStyleScope.of(context)?.styles)
      ..addPreamble(['热量结算', '${snapshot['from']} 至 ${snapshot['to']}'])
      ..add(settlementHeaders);
    for (final row in settlementCells(snapshot)) {
      csv.add(row);
    }
    try {
      final saved = await csv.save(
        '热量结算_${snapshot['from']}_${snapshot['to']}.csv',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(saved ? '导出已完成' : '已取消导出')));
      }
    } catch (e) {
      if (mounted) setState(() => error = '导出失败：$e');
    }
  }

  @override
  void dispose() {
    generation++;
    date.dispose();
    end.dispose();
    refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    child: LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (box.maxHeight >= 300)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                '热量结算 · 指定八站一次网',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: box.maxHeight < 300 ? 4 : 12,
            ),
            child: QueryToolbar(
              maxHeight: box.maxHeight * .48,
              fields: [
                SizedBox(
                  width: 135,
                  child: DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '统计周期'),
                    items: const [
                      DropdownMenuItem(value: 'hourly', child: Text('小时')),
                      DropdownMenuItem(value: 'daily', child: Text('日')),
                      DropdownMenuItem(value: 'monthly', child: Text('月')),
                      DropdownMenuItem(value: 'season', child: Text('采暖季')),
                    ],
                    onChanged: (v) {
                      mode = v!;
                      changed();
                    },
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: DateTimeField(
                    key: const Key('settlement-date'),
                    controller: date,
                    label: mode == 'daily'
                        ? '开始日期（含）'
                        : mode == 'monthly'
                        ? '所在月份'
                        : mode == 'season'
                        ? '采暖季内日期'
                        : '日期',
                    onChanged: (_) => changed(),
                  ),
                ),
                if (mode == 'daily')
                  SizedBox(
                    width: 180,
                    child: DateTimeField(
                      controller: end,
                      label: '结束日期（含）',
                      onChanged: (_) => changed(),
                    ),
                  ),
                TextButton.icon(
                  key: const Key('heat-price-history'),
                  onPressed: loading ? null : history,
                  icon: const Icon(Icons.show_chart, size: 18),
                  label: const Text('历年价格'),
                ),
              ],
              actions: [
                FilledButton.icon(
                  onPressed: loading || busy ? null : query,
                  icon: const Icon(Icons.calculate_outlined),
                  label: Text(busy ? '查询中…' : '生成报表'),
                ),
                OutlinedButton.icon(
                  onPressed: report == null ? null : export,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出'),
                ),
              ],
            ),
          ),
          if (loading || busy) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              report == null
                  ? '$priceLabel · 八站共享；采暖季11月5日至次年4月5日（含）'
                  : '${report!['from']} 至 ${report!['to']}',
              maxLines: box.maxHeight < 300 ? 1 : null,
              overflow: box.maxHeight < 300 ? TextOverflow.ellipsis : null,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (error != null || storageError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                [error, storageError].whereType<String>().join('\n'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: DenseTable(
              reportStyle: true,
              emphasizedRows: report == null
                  ? const {}
                  : {objects(report!['rows']).length},
              headers: settlementHeaders,
              rows: report == null ? const [] : settlementCells(report!),
              initialWidths: const [170, 150, 150, 145, 160],
              numericColumns: const {2, 3, 4},
              emptyLabel: '选择统计周期并生成结算报表；单价在“历年价格”中维护',
            ),
          ),
        ],
      ),
    ),
  );
}
