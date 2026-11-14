import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/report_time.dart';
import 'package:universal_hmi/shared/report_time_editor.dart';
import 'package:universal_hmi/shared/report_style.dart';
import 'package:universal_hmi/shared/report_style_transfer.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/table_csv.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/report_designer.dart';
import 'package:universal_hmi/features/external_data/statistics_grid.dart';
import 'energy_statistics_test.dart' show EnergyApi;

void main() {
  final zone = <String, dynamic>{
    'source_offset_minutes': 0,
    'target_offset_minutes': 480,
  };
  test(
    'statistics retains explicit timestamp offsets for the shared converter',
    () {
      final grid = StatisticsGrid(
        records: [
          {
            'date': '2026-01-01',
            'station': 'A',
            'hour': '2026-01-01T20:00:00+08:00',
            'metric': 'heat',
            'label': '热量',
            'unit': 'GJ',
          },
        ],
        columns: [
          {'key': 'hour', 'label': '时间', 'visible': true},
        ],
        energy: false,
        mode: 'hourly',
        format: (r, key, {exporting = false}) =>
            '${r[key]}'.replaceFirst('T', ' ').replaceFirst('+08:00', ''),
      );
      expect(grid.cells(0), ['2026-01-01 20:00:00']);
      expect(grid.cells(0, rawTime: true), ['2026-01-01T20:00:00+08:00']);
    },
  );
  testWidgets(
    'column setting saves, reopens and resets without changing query data',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      Json selected = {
        'id': 'time',
        'kind': 'alarm',
        'name': '报警',
        'revision': 1,
        'source_id': 'source',
      };
      final api = EnergyApi()..savedScreen = selected;
      final catalog = ExternalCatalog(api, canDevelop: true)
        ..loaded = true
        ..screens = [selected];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ReportStyleHost(
                screen: selected,
                child: Column(
                  children: [
                    ReportStyleAction(
                      catalog: catalog,
                      screen: selected,
                      onSaved: (v) => update(() => selected = v),
                    ),
                    const Expanded(
                      child: DenseTable(
                        reportTableKey: 'alarm',
                        columnKeys: ['event_time'],
                        headers: ['事件时间'],
                        rows: [
                          ['2026-01-01 20:00:00'],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('column-time-zone')));
      await t.pumpAndSettle();
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await t.tap(find.text('应用到列'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存样式'));
      await t.pumpAndSettle();
      expect(
        api.savedScreen['report_layouts']['alarm']['columns'][0]['time_zone'],
        zone,
      );
      expect(find.text('2026-01-02 04:00:00'), findsOneWidget);
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('column-time-zone')));
      await t.pumpAndSettle();
      expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value, true);
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await t.tap(find.text('应用到列'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存样式'));
      await t.pumpAndSettle();
      expect(
        api.savedScreen['report_layouts']['alarm']['columns'][0]['time_zone'],
        isNull,
      );
      expect(find.text('2026-01-01 20:00:00'), findsOneWidget);
      expect(api.queryCount, 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
  test(
    'fixed offsets cross dates, preserve precision and honor explicit source zones',
    () {
      for (final pair in {
        '2026-12-31 20:12:13.123456789': '2027-01-01 04:12:13.123456789',
        '2026-01-01T20:00:00Z': '2026-01-02 04:00:00',
        '2026-01-01T20:00:00+08:00': '2026-01-01 20:00:00',
        '2026-01-01T20:00:00-0330': '2026-01-02 07:30:00',
        '2024-02-29 23:30': '2024-03-01 07:30',
      }.entries) {
        expect(reportTime(pair.key, zone), pair.value);
      }
      expect(
        reportTime('2026-01-01 01:00:00', {
          'source_offset_minutes': 480,
          'target_offset_minutes': -210,
        }),
        '2025-12-31 13:30:00',
      );
      for (final value in [
        '',
        '—',
        '2026-01-01',
        '08:00',
        '2026-02-30 08:00:00',
        '2026-01-01 24:01:00',
        '2026-01-01T01:00:00+14:30',
        '123.45',
        '报警恢复',
      ]) {
        expect(reportTime(value, zone), value);
      }
    },
  );
  test(
    'column default, explicit raw timezone and CSV share conversion without losing numeric precision',
    () {
      final layout = {
        'columns': [
          {'key': 'time', 'label': '时间', 'visible': true, 'time_zone': zone},
          {'key': 'number', 'label': '数值', 'visible': true, 'decimals': 2},
        ],
      };
      final values = ['2026-01-01 20:00:00', '1234567890123456.123456'];
      final raw = ['2026-01-01T20:00:00+08:00', values[1]];
      final projection = ReportProjection(['time', 'number'], layout);
      expect(
        ReportProjection(
          ['n'],
          {
            'columns': [
              {'key': 'n', 'visible': true, 'time_zone': zone},
            ],
          },
        ).row(['12.35'], rawValues: ['12.3456']),
        ['12.35'],
      );
      expect(
        ReportProjection(
          ['n'],
          {
            'columns': [
              {'key': 'n', 'visible': true, 'decimals': 2, 'time_zone': zone},
            ],
          },
        ).row(['12.35'], rawValues: ['12.3456']),
        ['12.35'],
      );
      expect(projection.row(values, rawValues: raw).first, values.first);
      expect(ReportProjection(['time'], {}).row([values.first]), [
        values.first,
      ]);
      final styles = ReportStyles({
        'report_layouts': {'x': layout},
      });
      final csv =
          TableCsv(
              styles: styles,
              reportTableKey: 'x',
              columnKeys: ['time', 'number'],
            )
            ..add(['时间', '数值'])
            ..add(values, rawValues: raw);
      expect(
        utf8.decode(csv.bytes),
        contains('"2026-01-01 20:00:00","${values[1]}"'),
      );
      expect(
        validateReportStyle(layout, [
          'time',
          'number',
        ])['columns'][0]['time_zone'],
        zone,
      );
      for (final invalid in [
        {},
        {'source_offset_minutes': 0},
        {'source_offset_minutes': 0, 'target_offset_minutes': 841},
        {'source_offset_minutes': 'UTC', 'target_offset_minutes': 480},
      ]) {
        expect(
          () => validateReportStyle(
            {
              'columns': [
                {
                  'key': 'time',
                  'label': '时间',
                  'visible': true,
                  'time_zone': invalid,
                },
              ],
            },
            ['time'],
          ),
          throwsFormatException,
        );
      }
    },
  );
  testWidgets('shared table converts only the configured column', (t) async {
    final styles = ReportStyles({
      'report_layouts': {
        'x': {
          'columns': [
            {'key': 'a', 'label': '转换时间', 'visible': true, 'time_zone': zone},
            {'key': 'b', 'label': '原时间', 'visible': true},
          ],
        },
      },
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportStyleScope(
            styles: styles,
            child: const DenseTable(
              reportTableKey: 'x',
              columnKeys: ['a', 'b'],
              headers: ['转换时间', '原时间'],
              rows: [
                ['2026-01-01 20:00:00', '2026-01-01 20:00:00'],
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('2026-01-02 04:00:00'), findsOneWidget);
    expect(find.text('2026-01-01 20:00:00'), findsOneWidget);
  });
  testWidgets(
    'timezone dialog defaults off, applies a draft, and can disable it',
    (t) async {
      Json? result;
      Future<void> mount(Json? value) async {
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<Json>(
                      context: context,
                      builder: (_) =>
                          ReportTimeEditor(label: '事件时间', value: value),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('打开'));
        await t.pumpAndSettle();
      }

      await mount(null);
      expect(
        t.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      expect(find.textContaining('→ 2026-01-01 08:00:00'), findsOneWidget);
      await t.tap(find.text('应用到列'));
      await t.pumpAndSettle();
      expect(result, {'time_zone': zone});
      await mount(zone);
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await t.tap(find.text('应用到列'));
      await t.pumpAndSettle();
      expect(result, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
