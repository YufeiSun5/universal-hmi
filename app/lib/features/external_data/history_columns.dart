import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/form_control_theme.dart';
import 'alarm_columns.dart';
import 'catalog.dart';

const historyFields = {
  'target_time': '目标时间',
  'sample_time': '实际采样时间',
  'match': '匹配',
  'quality': '质量',
};

List<Json> historyLayout(Json screen) => screen['history_columns'] == null
    ? [
        for (final f in historyFields.entries)
          {'key': f.key, 'label': f.value, 'visible': f.key == 'target_time'},
      ]
    : [for (final c in screen['history_columns']) Map<String, dynamic>.from(c)];

class HistoryColumnAction extends StatelessWidget {
  const HistoryColumnAction({
    super.key,
    required this.catalog,
    required this.screen,
    this.onSaved,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final ValueChanged<Json>? onSaved;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.view_column_outlined),
    label: const Text('显示列配置'),
    onPressed: () async {
      final saved = await showDialog<Json>(
        context: context,
        builder: (_) => FormControlTheme(
          child: ExternalColumnEditor(
            catalog: catalog,
            screen: screen,
            fields: historyFields,
            layoutKey: 'history_columns',
            title: '历史附加列配置（数值始终显示）',
            fileFormat: 'universal-hmi-history-columns',
            defaults: historyLayout(screen),
            allowEmpty: true,
          ),
        ),
      );
      if (saved != null) {
        await catalog.load();
        onSaved?.call(saved);
      }
    },
  );
}
