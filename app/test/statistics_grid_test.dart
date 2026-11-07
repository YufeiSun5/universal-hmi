import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/statistics_grid.dart';
import 'package:universal_hmi/shared/api.dart';

String raw(Json row, String key, {bool exporting = false}) =>
    '${row[key] ?? '—'}';
List<Json> columns(List<String> keys) => [
  for (final key in keys) {'key': key, 'label': key},
];
void main() {
  test(
    'energy pivot keeps stations and dates separate, preserves zero, null and precision',
    () {
      final records = <Json>[
        for (final date in ['2026-11-02', '2026-11-03'])
          for (final station in ['01-001', '01-002'])
            for (final metric in ['electricity', 'heat', 'water'])
              {
                'date': date,
                'station': station,
                'metric': metric,
                'label': metric,
                'unit': metric == 'heat'
                    ? 'GJ'
                    : metric == 'water'
                    ? 't'
                    : 'kWh',
                'day_usage': metric == 'electricity'
                    ? '0.00000000'
                    : metric == 'heat'
                    ? '12345678901234567890.12345678'
                    : null,
                'day_subtotal': '999.00000000',
              },
      ];
      final grid = StatisticsGrid(
        records: records,
        columns: columns(['date', 'station', 'label', 'unit', 'day_usage']),
        energy: true,
        mode: 'daily',
        format: raw,
      );
      expect(grid.rows.length, 4);
      expect(grid.cells(0, exporting: true), [
        '2026-11-02',
        '01-001',
        '—',
        '0.00000000',
        '12345678901234567890.12345678',
      ]);
      expect(grid.cells(3)[0], '2026-11-03');
      expect(grid.cells(3)[1], '01-002');
      expect(grid.exportHeaders, [
        'date',
        'station',
        'water (t) · day_usage',
        'electricity (kWh) · day_usage',
        'heat (GJ) · day_usage',
      ]);
    },
  );
  test(
    'runtime omits empty hourly metrics but keeps zero and individual gaps',
    () {
      final records = <Json>[
        for (final hour in ['00:00', '01:00']) ...[
          {
            'date': '2026-11-05',
            'station': '01-002-01',
            'hour': hour,
            'metric': 'temperature',
            'label': '室外温度',
            'unit': '℃',
            'hour_min': hour == '00:00' ? '0' : null,
            'hour_max': hour == '00:00' ? '15.9' : null,
          },
          {
            'date': '2026-11-05',
            'station': '01-002-01',
            'hour': hour,
            'metric': 'pump3',
            'label': '循环泵3',
            'unit': 'A',
          },
        ],
      ];
      for (final includeEmpty in [false, true]) {
        final grid = StatisticsGrid(
          records: records,
          columns: columns([
            'hour',
            'label',
            'unit',
            'hour_usage',
            'hour_min',
            'hour_max',
          ]),
          energy: false,
          mode: 'hourly',
          includeEmptyMetrics: includeEmpty,
          format: raw,
        );
        expect(grid.headerGroups.any((x) => x.contains('循环泵3')), includeEmpty);
        expect(grid.exportHeaders.any((x) => x.contains('循环泵3')), includeEmpty);
        expect(grid.cells(0).sublist(0, 3), ['00:00', '0', '15.9']);
        expect(grid.cells(1).sublist(0, 3), ['01:00', '—', '—']);
      }
    },
  );
  test(
    'hour rows show difference and range without hiding completely missing metrics',
    () {
      final records = <Json>[
        for (final hour in ['00:00', '01:00']) ...[
          {
            'date': '2026-11-03',
            'station': 'A',
            'hour': hour,
            'metric': 'Value06',
            'label': 'Heat',
            'unit': 'GJ',
            'hour_usage': '0',
          },
          {
            'date': '2026-11-03',
            'station': 'A',
            'hour': hour,
            'metric': 'Value01',
            'label': 'Temperature',
            'unit': 'C',
            'hour_min': '10',
            'hour_max': '30',
          },
          {
            'date': '2026-11-03',
            'station': 'A',
            'hour': hour,
            'metric': 'Value31',
            'label': 'Missing',
            'unit': 'GJ',
          },
        ],
      ];
      final grid = StatisticsGrid(
        records: records,
        columns: columns([
          'hour',
          'label',
          'unit',
          'hour_usage',
          'hour_min',
          'hour_max',
        ]),
        energy: false,
        mode: 'hourly',
        format: raw,
      );
      expect(grid.rows.length, 2);
      expect(grid.cells(0), ['00:00', '0', '10', '30', '—', '—', '—']);
      expect(grid.headerGroups, [
        '',
        'Heat (GJ)',
        'Temperature (C)',
        'Temperature (C)',
        'Missing (GJ)',
        'Missing (GJ)',
        'Missing (GJ)',
      ]);
    },
  );
}
