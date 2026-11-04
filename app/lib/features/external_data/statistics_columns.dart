import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/form_control_theme.dart';
import 'alarm_columns.dart';
import 'catalog.dart';

Map<String, String> statisticsFields(bool energy) => {
  'date': '日期',
  'station': '站点',
  'label': '指标',
  'unit': '单位',
  'hour': '时间',
  'hour_usage': energy ? '小时用量' : '小时差额',
  if (!energy) 'hour_min': '小时最小值',
  if (!energy) 'hour_max': '小时最大值',
  'hour_status': '小时状态',
  'day_usage': energy ? '日用量' : '日差额',
  if (!energy) 'day_min': '日最小值',
  if (!energy) 'day_max': '日最大值',
  'day_status': '日状态',
  'progress': '统计进度',
  'sample_min': '参与采样最早',
  'sample_max': '参与采样最晚',
  'day_subtotal': '日差额小计（核查）',
};

List<Json> statisticsLayout(Json screen) => screen['statistics_columns'] == null
    ? [
        for (final f in statisticsFields(screen['kind'] == 'energy').entries)
          {
            'key': f.key,
            'label': f.value,
            'visible': const {
              'date',
              'station',
              'label',
              'unit',
              'hour',
              'hour_usage',
              'hour_min',
              'hour_max',
              'day_usage',
              'day_min',
              'day_max',
            }.contains(f.key),
          },
      ]
    : [
        for (final c in screen['statistics_columns'])
          Map<String, dynamic>.from(c),
      ];

class StatisticsColumnAction extends StatelessWidget {
  const StatisticsColumnAction({
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
            fields: statisticsFields(screen['kind'] == 'energy'),
            layoutKey: 'statistics_columns',
            title: '统计显示列配置',
            fileFormat: 'universal-hmi-statistics-columns',
            defaults: statisticsLayout(screen),
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
