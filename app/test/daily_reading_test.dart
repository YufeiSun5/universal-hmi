import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/daily_reading.dart';
import 'package:universal_hmi/features/external_data/statistics_columns.dart';
import 'package:universal_hmi/features/external_data/statistics_grid.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  test('runtime daily values do not expose mixed-type diagnostic text', () {
    expect(
      dailyReading(
        {'statistic_kind': 'mixed'},
        readableDecimal,
        diagnostics: false,
      ),
      '—',
    );
    expect(
      dailyReading(
        {'statistic_kind': 'mixed'},
        readableDecimal,
        diagnostics: true,
      ),
      '统计类型变化',
    );
  });
  test('daily report and CSV use one readable usage or range per metric', () {
    final records =
        <Json>[
              {
                'metric': 'temp',
                'label': '供水温度',
                'unit': '℃',
                'statistic_kind': 'range',
                'day_min': '31.10000000',
                'day_max': '36.00000000',
              },
              {
                'metric': 'pressure',
                'label': '压力',
                'unit': 'MPa',
                'statistic_kind': 'range',
                'day_min': '0.00000000',
                'day_max': '0.00000000',
              },
              {
                'metric': 'heat',
                'label': '热量',
                'unit': 'GJ',
                'statistic_kind': 'usage',
                'day_usage': null,
                'day_subtotal': '828.00000000',
              },
              {
                'metric': 'power',
                'label': '电量',
                'unit': 'kWh',
                'statistic_kind': 'usage',
                'day_subtotal': '0.00000000',
              },
              {
                'metric': 'missing',
                'label': '未接入',
                'unit': 't',
                'statistic_kind': 'usage',
              },
            ]
            .map(
              (r) => <String, dynamic>{
                ...r,
                'date': '2026-11-05',
                'station': 'A',
                'day_status': '不完整',
                'valid_hours': '18',
              },
            )
            .toList();
    // Old custom layouts are projected into the simplified display, without
    // changing raw API fields or needing the user to repair each saved screen.
    final layout = statisticsLayout({
      'kind': 'daily',
      'statistics_columns': [
        {'key': 'station', 'label': '站点', 'visible': true},
        {'key': 'date', 'label': '日期', 'visible': true},
        {'key': 'day_usage', 'label': '完整日用量', 'visible': true},
        {'key': 'day_subtotal', 'label': '小计', 'visible': true},
        {'key': 'valid_hours', 'label': '有效小时数', 'visible': true},
      ],
    });
    final grid = StatisticsGrid(
      records: records,
      columns: layout,
      energy: false,
      mode: 'daily',
      format: (r, k, {exporting = false}) => k == 'day_value'
          ? dailyReading(r, readableDecimal)
          : '${r[k] ?? '—'}',
    );
    expect(grid.cells(0, exporting: true), [
      'A',
      '2026-11-05',
      '31.1～36',
      '0～0',
      '828',
      '0',
      '—',
    ]);
    expect(grid.headers, ['站点', '日期', '范围', '范围', '用量', '用量', '用量']);
    expect(
      grid.exportHeaders.where(
        (h) => h.contains('小计') || h.contains('完整日') || h.contains('小时数'),
      ),
      isEmpty,
    );
    expect(records[2]['day_usage'], isNull);
    expect(
      dailyReading({
        ...records[2],
        'day_usage': '900.00000000',
      }, readableDecimal),
      '900',
    );
  });
  test(
    'mixed mode, partial range, missing and high precision remain honest',
    () {
      expect(
        dailyReading({'statistic_kind': 'mixed'}, readableDecimal),
        '统计类型变化',
      );
      expect(
        dailyReading({
          'statistic_kind': 'range',
          'day_min': '0.00000000',
        }, readableDecimal),
        '0～—',
      );
      expect(dailyReading({'statistic_kind': 'range'}, readableDecimal), '—');
      expect(
        dailyReading({
          'statistic_kind': 'usage',
          'day_subtotal': '12345678901234567890.12345678',
        }, readableDecimal),
        '12345678901234567890.12345678',
      );
    },
  );
}
