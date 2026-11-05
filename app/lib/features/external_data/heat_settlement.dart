import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/date_time_field.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';
import '../../platform/settlement_price.dart';

const settlementHeaders = ['统计周期', '站点', '热量（GJ）', '单价（元/GJ）', '金额（元）', '统计情况'];
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
      settlementNumber(report['unit_price']),
      row['amount']?.toString() ?? '—',
      '${row['status']}',
    ],
  [
    '合计',
    '',
    settlementNumber(report['total_heat']),
    '',
    report['total_amount']?.toString() ?? '—',
    (report['incomplete'] ?? 0) == 0 ? '金额按各行分位相加' : '存在缺数，合计未生成',
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
  final price = TextEditingController();
  String mode = 'daily', server = '', user = '';
  String? error, storageError;
  bool loading = true, busy = false, saving = false;
  bool identityReady = false;
  int generation = 0;
  Json? report;
  @override
  void initState() {
    super.initState();
    loadPrice();
  }

  Future<void> loadPrice() async {
    try {
      final identity = widget.api;
      if (identity is! PersonalPreferenceIdentity) {
        throw StateError('无法识别当前账号的本机设置');
      }
      server = (identity as PersonalPreferenceIdentity).preferenceServer;
      user = (identity as PersonalPreferenceIdentity).preferenceUser;
      identityReady = true;
      final saved = await loadSettlementPrice(server, user);
      if (mounted) price.text = saved ?? '';
    } catch (e) {
      storageError = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  bool get validPrice => RegExp(
    r'^(0|[1-9][0-9]{0,7})(\.[0-9]{1,6})?$',
  ).hasMatch(price.text.trim());
  void changed() => setState(() {
    generation++;
    busy = false;
    report = null;
    error = null;
  });
  Future<void> persist({bool clear = false}) async {
    if (!identityReady) return;
    if (!clear && !validPrice) {
      setState(() => storageError = '请填写有效单价，最多6位小数');
      return;
    }
    setState(() {
      saving = true;
      storageError = null;
    });
    try {
      await saveSettlementPrice(server, user, clear ? '' : price.text.trim());
      if (!mounted) return;
      if (clear) {
        price.clear();
        changed();
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(clear ? '已清除本机单价' : '单价已保存到本机')));
    } catch (e) {
      if (mounted) setState(() => storageError = '$e');
    }
    if (mounted) setState(() => saving = false);
  }

  Future<void> query() async {
    if (!validPrice) {
      setState(() => error = '请填写有效热量单价（元/GJ）');
      return;
    }
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = null;
      report = null;
    });
    final input = <String, dynamic>{
      'mode': 'settlement_$mode',
      'date': date.text.trim(),
      'unit_price': price.text.trim(),
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
      // Freeze the price used by this query; later edits cannot alter this report.
      try {
        if (identityReady) {
          await saveSettlementPrice(
            server,
            user,
            input['unit_price'] as String,
          );
        }
      } catch (e) {
        if (mounted && ticket == generation) {
          setState(() => storageError = '$e');
        }
      }
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    }
    if (mounted && ticket == generation) setState(() => busy = false);
  }

  Future<void> export() async {
    final snapshot = report;
    if (snapshot == null) return;
    final csv = TableCsv()
      ..add([
        '热量结算',
        '${snapshot['from']} 至 ${snapshot['to']}',
        '统计截至 ${snapshot['as_of']}',
      ])
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
    price.dispose();
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
                  width: 170,
                  child: TextField(
                    key: const Key('settlement-price'),
                    controller: price,
                    enabled: !loading && !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '统一单价（元/GJ）'),
                    onChanged: (_) => changed(),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: DateTimeField(
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
                OutlinedButton(
                  onPressed: loading || saving || !identityReady
                      ? null
                      : persist,
                  child: const Text('记住单价'),
                ),
                TextButton(
                  onPressed: loading || saving || !identityReady
                      ? null
                      : () => persist(clear: true),
                  child: const Text('清除'),
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
                  ? '单价仅保存在当前账号的本机；采暖季为11月5日至次年4月5日（含）。'
                  : '${report!['from']} 至 ${report!['to']} · 统计截至 ${report!['as_of']}\n未结束周期显示已有统计；缺数为 —，不生成对应金额。',
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
              headers: settlementHeaders,
              rows: report == null ? const [] : settlementCells(report!),
              initialWidths: const [170, 150, 150, 145, 160, 190],
              numericColumns: const {2, 3, 4},
              emptyLabel: '填写单价并生成结算报表',
            ),
          ),
        ],
      ),
    ),
  );
}
