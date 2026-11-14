import 'package:flutter/material.dart';
import 'api.dart';
import 'report_time.dart';

class ReportTimeEditor extends StatefulWidget {
  const ReportTimeEditor({super.key, required this.label, this.value});
  final String label;
  final Json? value;
  @override
  State<ReportTimeEditor> createState() => _ReportTimeEditorState();
}

class _ReportTimeEditorState extends State<ReportTimeEditor> {
  late bool enabled = widget.value != null;
  late int source = widget.value?['source_offset_minutes'] as int? ?? 0;
  late int target = widget.value?['target_offset_minutes'] as int? ?? 480;
  Json get zone => {
    'source_offset_minutes': source,
    'target_offset_minutes': target,
  };
  Widget select(String label, int value, ValueChanged<int> change) =>
      DropdownButtonFormField<int>(
        initialValue: value,
        isExpanded: true,
        menuMaxHeight: 300,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final n in <int>{
            0,
            480,
            value,
            for (var n = -840; n <= 840; n += 15) n,
          })
            DropdownMenuItem(value: n, child: Text(reportTimeZoneLabel(n))),
        ],
        onChanged: enabled ? (v) => setState(() => change(v!)) : null,
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.label} · 时区转换'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用时区转换'),
              subtitle: const Text('默认关闭，保留原时间'),
              value: enabled,
              onChanged: (v) => setState(() => enabled = v),
            ),
            const SizedBox(height: 12),
            select('来源时区（无时区时间）', source, (v) => source = v),
            const SizedBox(height: 16),
            select('显示时区', target, (v) => target = v),
            const SizedBox(height: 16),
            const Text(
              '带 Z 或时区的时间按其自身时区转换。仅日期、空值和非时间内容保持原样。使用固定 UTC 偏移，不自动切换夏令时。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text(
              '示例：2026-01-01 00:00:00 → ${enabled ? reportTime('2026-01-01 00:00:00', zone) : '2026-01-01 00:00:00'}',
            ),
            const SizedBox(height: 12),
            const Text(
              '只影响本列显示和导出；查询条件、确认人匹配和数据库原值不变。应用后还需保存报表样式。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, dynamic>{
          if (enabled) 'time_zone': zone,
        }),
        child: const Text('应用到列'),
      ),
    ],
  );
}
