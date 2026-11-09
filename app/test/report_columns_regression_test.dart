import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/report_designer.dart';
import 'package:universal_hmi/features/external_data/workspace.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/features/external_data/heat_settlement.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/report_style.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/table_csv.dart';
import 'energy_statistics_test.dart' show EnergyApi, energy;
import 'heat_settlement_test.dart' show SettlementApi;
import 'workspace_test.dart' show FakeApi;

void main() {
  testWidgets(
    'runtime receives saved styles without rerunning the database query',
    (t) async {
      final api = EnergyApi();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportStyleHost(
              api: api,
              screen: energy,
              child: StatisticsQuery(api: api, screen: energy),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final raw = t.widget<DenseTable>(find.byType(DenseTable));
      final queryCount = api.queryCount;
      api.savedScreen = {
        ...energy,
        'revision': 2,
        'report_layouts': {
          'statistics_current': {
            'columns': [
              for (final key in raw.columnKeys!)
                {
                  'key': key,
                  'label': key == 'station' ? '供热站点' : key,
                  'visible': key == 'station',
                },
            ],
          },
        },
      };
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(t.widget<DenseTable>(find.byType(DenseTable).last).headers, [
        '供热站点',
      ]);
      expect(api.queryCount, queryCount);
      api.savedScreen = {...energy};
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(t.widget<DenseTable>(find.byType(DenseTable).last).headers, [
        '供热站点',
      ]);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final size in [const Size(390, 844), const Size(420, 360)]) {
    testWidgets('column editor remains usable at $size', (t) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final screen = <String, dynamic>{'id': 'custom', 'kind': 'custom'};
      final catalog = ExternalCatalog(FakeApi(), canDevelop: true)
        ..screens = [screen];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportStyleHost(
              screen: screen,
              child: Column(
                children: [
                  ReportStyleAction(catalog: catalog, screen: screen),
                  const Expanded(
                    child: DenseTable(
                      headers: ['站点', '热量'],
                      rows: [
                        ['中心站', '12.3456'],
                      ],
                      reportStyle: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      expect(find.text('当前结果共 2 列 · 显示 2 列'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
    });
  }
  testWidgets(
    'saving order visibility and decimals updates current results and survives reopening',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = EnergyApi()
        ..readings = [
          for (final metric in ['water', 'electricity', 'heat'])
            {
              'date': '2026-11-09',
              'station': '01-001',
              'name': '中心站',
              'metric': metric,
              'label': metric,
              'unit': metric == 'heat' ? 'GJ' : 't',
              'day_usage': metric == 'heat'
                  ? '12345678901234567890.12345678'
                  : metric == 'water'
                  ? null
                  : '0.00000000',
            },
        ];
      final catalog = ExternalCatalog(api, canDevelop: true)
        ..loaded = true
        ..screens = [energy];
      Json selected = {...energy};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ExternalWorkspace(
                catalog: catalog,
                screen: selected,
                development: true,
                onOpen: (s) => update(() => selected = s!),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      final queries = api.queryCount;
      final original = t.widget<DenseTable>(find.byType(DenseTable));
      final heat = original.columnKeys!.last;
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      await t.tap(find.byType(Checkbox).first);
      await t.pumpAndSettle();
      expect(find.text('当前结果共 5 列 · 显示 4 列'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        final move = find.byKey(ValueKey('move-up-$heat'));
        await t.ensureVisible(move);
        await t.pumpAndSettle();
        await t.tap(move);
        await t.pump();
      }
      final label = find.byKey(ValueKey('statistics_current_${heat}_label'));
      await t.ensureVisible(label);
      await t.enterText(label, '本期热量');
      await t.pumpAndSettle();
      final row = find.byKey(ValueKey('1-$heat'));
      final decimals = find.descendant(
        of: row,
        matching: find.byType(DropdownButtonFormField<int>),
      );
      await t.ensureVisible(decimals);
      await t.pumpAndSettle();
      await t.tap(decimals);
      await t.pumpAndSettle();
      await t.tap(find.text('4').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存样式'));
      await t.pumpAndSettle();
      expect(
        api.queryCount,
        queries,
        reason: 'style save must retain the queried rows',
      );
      expect(t.widget<DenseTable>(find.byType(DenseTable).last).headers, [
        '本期热量',
        '站点',
        '日用量',
        '日用量',
      ]);
      expect(find.text('12345678901234567890.1235'), findsOneWidget);
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      expect(find.text('当前结果共 5 列 · 显示 4 列'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      // A fresh runtime query has fewer metrics; the surviving field keeps its setting.
      api.readings!.removeAt(0);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExternalWorkspace(
              catalog: catalog,
              screen: selected,
              autoQuery: true,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.widget<DenseTable>(find.byType(DenseTable).last).headers, [
        '本期热量',
        '站点',
        '日用量',
      ]);
      expect(find.text('12345678901234567890.1235'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editor tracks only the current table after query columns change',
    (t) async {
      final screen = <String, dynamic>{'id': 's', 'kind': 'standard'};
      final catalog = ExternalCatalog(FakeApi(), canDevelop: true)
        ..screens = [screen];
      final styles = ReportStyles(screen);
      Future<void> show(List<String> fields) => t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportStyleScope(
              styles: styles,
              child: Column(
                children: [
                  ReportStyleAction(catalog: catalog, screen: screen),
                  Expanded(
                    child: DenseTable(
                      key: ValueKey(fields.join()),
                      reportStyle: true,
                      headers: fields,
                      rows: [fields],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await show(['旧站点', '旧温度']);
      await show(['站点', '热量', '电量', '水量']);
      await t.pumpAndSettle();
      expect(styles.schemas.values.single, ['站点', '热量', '电量', '水量']);
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      expect(find.text('当前结果共 4 列 · 显示 4 列'), findsOneWidget);
      expect(find.text('旧温度'), findsNothing);
      expect(
        find
            .byType(DropdownButtonFormField<String>)
            .evaluate()
            .where(
              (e) =>
                  (e.widget as DropdownButtonFormField<String>)
                      .decoration
                      .labelText ==
                  '表格',
            ),
        isEmpty,
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      expect(styles.schemas, isEmpty);
    },
  );

  testWidgets('query must supply dynamic columns before the editor opens', (
    t,
  ) async {
    final api = EnergyApi();
    final catalog = ExternalCatalog(api, canDevelop: true)
      ..loaded = true
      ..screens = [energy];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExternalWorkspace(
            catalog: catalog,
            screen: energy,
            development: true,
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('报表样式'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('请先查询报表'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('per-column precision uses original decimals and range bounds', (
    t,
  ) async {
    final styles = ReportStyles({
      'kind': 'daily',
      'report_layouts': {
        'statistics_daily': {
          'columns': [
            {'key': 'heat', 'label': '热量', 'visible': true, 'decimals': 4},
            {'key': 'range', 'label': '温度范围', 'visible': true, 'decimals': 3},
            {'key': 'zero', 'label': '零', 'visible': true, 'decimals': 3},
            {'key': 'null', 'label': '缺失', 'visible': true, 'decimals': 3},
          ],
        },
      },
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportStyleScope(
            styles: styles,
            child: DenseTable(
              reportStyle: true,
              reportTableKey: 'statistics_daily',
              columnKeys: const ['heat', 'range', 'zero', 'null'],
              headers: const ['用量', '范围', '零', '缺失'],
              rows: const [
                ['12345678901234567890.12', '12.35～45.68', '0.00', '—'],
              ],
              rawRowBuilder: (_) => [
                '12345678901234567890.12345678',
                '12.34567～45.67891',
                '0.00000',
                '—',
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('12345678901234567890.1235'), findsOneWidget);
    expect(find.text('12.346～45.679'), findsOneWidget);
    expect(find.text('0.000'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test(
    'same field keeps its style when other metrics disappear or reorder',
    () {
      final styles = ReportStyles({
        'report_layouts': {
          'statistics_hourly': {
            'columns': [
              {'key': 'heat', 'label': '热量GJ', 'visible': true, 'decimals': 3},
              {'key': 'date', 'label': '日期', 'visible': false},
              {'key': 'water', 'label': '水量', 'visible': true},
            ],
          },
        },
      });
      final layout = styles.layout([
        'date',
        'heat',
      ], tableKey: 'statistics_hourly');
      final p = ReportProjection(['date', 'heat'], layout);
      expect(p.headers, ['热量GJ']);
      expect(p.row(['2026-11-09', '12.34567']), ['12.346']);
      final larger = ReportProjection(
        ['water', 'heat', 'new', 'date'],
        styles.layout([
          'water',
          'heat',
          'new',
          'date',
        ], tableKey: 'statistics_hourly'),
      );
      expect(larger.headers, ['热量GJ', '水量', 'new']);
      expect(larger.row(['0', '12.34567', '—', '2026-11-09']), [
        '12.346',
        '0',
        '—',
      ]);
    },
  );

  test('legacy layouts migrate by source column instead of position', () {
    final legacyKeys = reportColumnKeys(
      ['日期', '用量', '用量'],
      groups: ['', '热量', '电量'],
      groupKeys: ['', 'heat', 'power'],
    );
    final styles = ReportStyles({
      'report_layouts': {
        reportSchemaKey(legacyKeys): {
          'columns': [
            {
              'key': legacyKeys[2],
              'label': '耗电',
              'visible': true,
              'decimals': 4,
            },
            {'key': legacyKeys[1], 'label': '耗热', 'visible': false},
          ],
        },
      },
    });
    final fields = ['date', 'heat', 'power'];
    final p = ReportProjection(
      fields,
      styles.layout(
        fields,
        tableKey: 'statistics_current',
        legacyKeys: legacyKeys,
      ),
    );
    expect(p.headers, ['耗电', 'date']);
    expect(p.row(['日期', '98.12', '0.123456']), ['0.1235', '日期']);
  });

  test(
    'settlement CSV skips preamble for projection and preserves raw precision',
    () {
      final styles = ReportStyles({
        'report_layouts': {
          reportSchemaKey(settlementHeaders): {
            'columns': [
              {'key': '金额（元）', 'label': '应收金额', 'visible': true, 'decimals': 0},
              {'key': '站点', 'label': '站点', 'visible': true},
              {'key': '热量（GJ）', 'label': '耗热', 'visible': true, 'decimals': 2},
              {'key': '统计周期', 'label': '周期', 'visible': false},
              {'key': '单价（元/GJ）', 'label': '单价', 'visible': false},
            ],
          },
        },
      });
      final csv = TableCsv(styles: styles)
        ..addPreamble(['热量结算', '2026-11-09'])
        ..add(settlementHeaders)
        ..add([
          '11月',
          '中心站',
          '12345678901234567890.12345678',
          '25.1234',
          '800.25',
        ]);
      expect(
        utf8.decode(csv.bytes),
        contains(
          '"应收金额","站点","耗热"\r\n"800.25","中心站","12345678901234567890.12345678"',
        ),
      );
      expect(
        styles.schemas,
        isEmpty,
        reason: 'export must not register stale tables',
      );
    },
  );

  testWidgets('settlement editor exposes exactly its five result columns', (
    t,
  ) async {
    final api = SettlementApi();
    final catalog = ExternalCatalog(api, canDevelop: true)
      ..loaded = true
      ..screens = [energy];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EnergyWorkspace(
            catalog: catalog,
            selectedID: 'energy/settlement',
            onSelected: (_) {},
            showDirectory: false,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('生成报表'));
    await t.pumpAndSettle();
    await t.tap(find.text('报表样式'));
    await t.pumpAndSettle();
    expect(find.text('当前结果共 5 列 · 显示 5 列'), findsOneWidget);
    expect(find.text('日用量'), findsNothing);
    expect(
      t
          .widget<ListView>(find.byKey(const ValueKey('result-column-list')))
          .childrenDelegate
          .estimatedChildCount,
      5,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
