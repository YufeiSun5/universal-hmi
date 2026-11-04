import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/form_control_theme.dart';
import 'alarm_columns.dart';
import 'catalog.dart';

Map<String, String> statisticsFields(bool energy, {bool daily = false}) => {
  'date': '日期',
  'station': '站点',
  'label': '指标',
  'unit': '单位',
  if (!energy) 'hour': '时间',
  if (!energy) 'hour_usage': '小时差额',
  if (!energy) 'hour_min': '小时最小值',
  if (!energy) 'hour_max': '小时最大值',
  if (!energy) 'hour_status': '小时状态',
  'day_usage': daily
      ? '完整日用量'
      : energy
      ? '日用量'
      : '日差额',
  if (!energy) 'day_min': '日最小值',
  if (!energy) 'day_max': '日最大值',
  'day_status': '日状态',
  'progress': '统计进度',
  'sample_min': '参与采样最早',
  'sample_max': '参与采样最晚',
  'day_subtotal': daily ? '已结算小计' : '日差额小计（核查）',
  if (daily) ...{
    'valid_hours': '有效小时数',
    'day_record': '有日表记录',
    'day_status_code': '日状态码',
    'day_anomaly': '本测点异常',
  },
};

List<Json> statisticsLayout(Json screen) => screen['statistics_columns'] == null
    ? [
        for (final f in statisticsFields(
          screen['kind'] == 'energy',
          daily: screen['kind'] == 'daily',
        ).entries)
          {
            'key': f.key,
            'label': f.value,
            'visible':
                const {
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
                }.contains(f.key) ||
                screen['kind'] == 'daily' &&
                    const {
                      'day_subtotal',
                      'day_status',
                      'valid_hours',
                    }.contains(f.key),
          },
      ]
    : [
        for (final c in screen['statistics_columns'])
          if (!(screen['kind'] == 'energy' && '${c['key']}'.startsWith('hour')))
            Map<String, dynamic>.from(c),
        for (final f in statisticsFields(
          screen['kind'] == 'energy',
          daily: screen['kind'] == 'daily',
        ).entries)
          if (!(screen['statistics_columns'] as List).any(
            (c) => c['key'] == f.key,
          ))
            {'key': f.key, 'label': f.value, 'visible': f.key == 'valid_hours'},
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
            fields: statisticsFields(
              screen['kind'] == 'energy',
              daily: screen['kind'] == 'daily',
            ),
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
