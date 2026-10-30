import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/variable_search.dart';
import 'model.dart';
import 'subscriptions.dart';

const gisMetrics = {
  'primary_supply': '一次侧供水温度',
  'primary_return': '一次侧回水温度',
  'secondary_supply': '二次侧供水温度',
  'secondary_return': '二次侧回水温度',
  'supply_pressure': '供水压力',
};

/// GIS is a cross-station presentation. Resolve only explicit stable identities;
/// reuse the shared quality formatter and never infer bindings from names.
Json gisReadings(
  Json? config,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  final result = <String, dynamic>{};
  for (final id in gisSubscriptionIDs(config)) {
    final sample = live[id];
    final value = processValue(
      ScreenElement({
        'kind': 'value',
        'point_id': id,
        'decimals': 2,
        'show_unit': false,
      }),
      ScreenDocument(id: 'gis-display', name: 'GIS', station: ''),
      definitions,
      live,
      online,
    );
    final numeric = sample?['value'] is num;
    result[id] = {
      'text': value.good && numeric ? value.text : '—',
      'quality': value.good && !numeric ? 'unsupported' : value.quality,
      'status': value.good
          ? (numeric ? '正常' : '非数值')
          : value.text.replaceFirst('— ', ''),
      'unit': (sample?['unit'] ?? definitions[id]?['unit'] ?? '').toString(),
      'tooltip': value.tooltip,
    };
  }
  return result;
}

class GisPointPicker extends StatefulWidget {
  const GisPointPicker({super.key, required this.definitions});
  final Map<String, Json> definitions;
  @override
  State<GisPointPicker> createState() => _GisPointPickerState();
}

class _GisPointPickerState extends State<GisPointPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final matcher = VariableSearch(query);
    final items = widget.definitions.entries
        .where(
          (entry) => matcher.matchesPoint({...entry.value, 'id': entry.key}),
        )
        .toList();
    return AlertDialog(
      title: const Text('选择浮窗变量'),
      content: SizedBox(
        width: 520,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: '搜索变量：*、?、逗号多条件'),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配变量，请先在变量管理中添加'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final entry = items[index], p = entry.value;
                        return ListTile(
                          dense: true,
                          title: Text('${p['station']} / ${p['name']}'),
                          subtitle: Text('${entry.key} · ${p['unit'] ?? ''}'),
                          onTap: () => Navigator.pop(context, entry.key),
                        );
                      },
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
      ],
    );
  }
}
