import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/pagination.dart';
import 'widgets.dart';
import 'session.dart';

String materialQuantities(Json summary) => objects(
  summary['quantities'],
).map((v) => '${v['quantity']} ${v['unit']}').join(' · ');

class MaterialPeriodSummary extends StatelessWidget {
  const MaterialPeriodSummary({
    super.key,
    required this.summary,
    required this.label,
    required this.onDetails,
    this.secondary = false,
  });
  final Json summary;
  final String label;
  final VoidCallback onDetails;
  final bool secondary;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: secondary ? const Color(0xffedf1f4) : Colors.white,
      border: Border.all(color: const Color(0xffd4dce2)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Wrap(
      spacing: 22,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text('${summary['documents']} 单 · ${summary['products']} 种物料'),
        Text(
          materialQuantities(summary).isEmpty
              ? '暂无数量'
              : materialQuantities(summary),
        ),
        Text(
          '已知金额 ¥${summary['known_amount']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if ((summary['missing_prices'] as int? ?? 0) > 0)
          Text(
            '缺价 ${summary['missing_prices']} 行',
            style: const TextStyle(color: Color(0xff98601e)),
          ),
        TextButton(onPressed: onDetails, child: const Text('按物料查看汇总')),
      ],
    ),
  );
}

Future<void> showMaterialSummary(
  BuildContext context,
  PlatformApi api,
  String endpoint,
  Json query, {
  bool returns = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SummaryDialog(
    api: api,
    endpoint: endpoint,
    query: query,
    returns: returns,
  ),
);

class _SummaryDialog extends StatefulWidget {
  const _SummaryDialog({
    required this.api,
    required this.endpoint,
    required this.query,
    required this.returns,
  });
  final PlatformApi api;
  final String endpoint;
  final Json query;
  final bool returns;
  @override
  State<_SummaryDialog> createState() => _SummaryDialogState();
}

class _SummaryDialogState extends State<_SummaryDialog> {
  Json summary = {};
  bool busy = false;
  String? error;
  int offset = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        widget.endpoint,
        query: {
          ...widget.query,
          'summary_offset': offset,
          'limit': 1,
          'offset': 0,
        },
      );
      if (mounted) {
        setState(
          () => summary =
              data[widget.returns ? 'return_summary' : 'summary'] as Json? ??
              {},
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 900,
      height: MediaQuery.sizeOf(context).height * .7,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.returns ? '本期发生退库 · 物料汇总' : '当前查询范围 · 物料汇总',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text('数量按各物料单位汇总；缺价不计为零，金额沿用原单快照。'),
            if (busy) const LinearProgressIndicator(),
            if (error != null) materialError(error!, retry: load),
            Expanded(
              child: MaterialTable(
                headers: const ['物料', '规格', '数量', '单位', '已知金额', '缺价行数'],
                rows: objects(summary['items'])
                    .map(
                      (v) => [
                        'name',
                        'specification',
                        'quantity',
                        'unit',
                        'known_amount',
                        'missing_prices',
                      ].map((k) => materialText(v, k)).toList(),
                    )
                    .toList(),
                empty: busy ? '正在查询…' : '没有匹配的物料',
              ),
            ),
            PaginationBar(
              total: summary['products'] as int? ?? 0,
              offset: offset,
              pageSize: 50,
              busy: busy,
              onChanged: (v) {
                offset = v;
                load();
              },
            ),
          ],
        ),
      ),
    ),
  );
}
