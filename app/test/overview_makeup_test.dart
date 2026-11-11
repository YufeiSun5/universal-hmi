import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/layout.dart';
import 'package:universal_hmi/features/live_overview/makeup.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'live_overview_test.dart' show OverviewApi;

List<Json> legacyColumns() => [
  for (final (i, column)
      in (jsonDecode(
                File(
                  'test/fixtures/overview_reference_columns.json',
                ).readAsStringSync(),
              )
              as List)
          .indexed)
    {...column as Json, 'id': 'c$i'},
];

void main() {
  test(
    'old column identities, formatting and custom columns survive pump layout',
    () {
      final old = legacyColumns();
      final current = old.singleWhere((c) => c['name'] == '补水电流');
      current['decimals'] = 3;
      current['header'] = '现场电流';
      old.add({'id': 'custom', 'group': '自定义', 'name': '备用测点', 'decimals': 2});
      final before = jsonEncode(old);
      var nextID = 0;
      final next = overviewMakeupLayout(old, newID: () => 'new${nextID++}');
      expect(jsonEncode(old), before);
      expect(next.length, old.length + 2);
      expect(next.where((c) => c['group'] == '补水水箱').map((c) => c['name']), [
        '水箱水位',
        '补水瞬时流量',
        '补水流量累计',
      ]);
      expect(next.where((c) => c['group'] == '补水泵1').map((c) => c['name']), [
        '补水电流',
        '补水频率',
      ]);
      expect(next.where((c) => c['group'] == '补水泵2').map((c) => c['name']), [
        '补水泵2电流',
        '补水泵2频率',
      ]);
      final changed = next.singleWhere((c) => c['id'] == current['id']);
      expect(changed['decimals'], 3);
      expect(changed['header'], '现场电流');
      for (final c in old.where((c) => !['补水电流', '补水频率'].contains(c['name']))) {
        expect(next.singleWhere((n) => n['id'] == c['id']), c);
      }
      expect(
        overviewMakeupLayout(
          next,
          newID: () => throw StateError('duplicate creation'),
        ),
        next,
      );
    },
  );

  test(
    'ambiguous names and 64-column overflow fail without mutating old columns',
    () {
      final old = legacyColumns();
      final duplicate = [
        ...old,
        {...old.singleWhere((c) => c['name'] == '补水电流'), 'id': 'other'},
      ];
      expect(
        () => overviewMakeupLayout(duplicate, newID: () => 'new'),
        throwsFormatException,
      );
      final crowded = [
        ...old,
        for (var i = old.length; i < 63; i++)
          {'id': 'x$i', 'name': '自定义$i', 'group': '其它', 'decimals': 1},
      ];
      final before = jsonEncode(crowded);
      var id = 0;
      expect(
        () => overviewMakeupLayout(crowded, newID: () => 'new${id++}'),
        throwsFormatException,
      );
      expect(jsonEncode(crowded), before);
    },
  );

  test(
    'pump columns stay shared across tank rows and roundtrip keeps every binding',
    () {
      final old = legacyColumns();
      var id = 0;
      final columns = overviewMakeupLayout(old, newID: () => 'new${id++}');
      final tank = old.singleWhere((c) => c['name'] == '水箱水位')['id'] as String;
      final rows = <Json>[
        {
          'id': 'area',
          'site': '中心所',
          'name': '中心站',
          'area': '一区',
          'station': 'A',
          'bindings': {for (final c in old) c['id']: 'p${c['id']}'},
          'additional': {
            'columns': [tank],
            'bindings': {tank: 'tank2'},
          },
        },
      ];
      final definitions = <String, Json>{
        for (final c in old)
          'p${c['id']}': {
            'id': 'p${c['id']}',
            'station': 'A',
            'name': c['name'],
          },
        'tank2': {'id': 'tank2', 'station': 'A', 'name': '第二水箱'},
      };
      final decoded = OverviewImport.decode(
        encodeOverview(columns, rows, {}),
        definitions,
      );
      expect(decoded.rows.single['bindings'], rows.single['bindings']);
      expect(decoded.rows.single['additional'], rows.single['additional']);
      final display = overviewDisplayRows(decoded.rows, decoded.columns);
      expect(display.length, 2);
      for (final pump in columns.where(
        (c) => '${c['group']}'.startsWith('补水泵'),
      )) {
        expect(overviewIsSplit(display.first, pump['id']), false);
        expect(
          (display.first['bindings'] as Map)[pump['id']],
          (display.last['bindings'] as Map)[pump['id']],
        );
        if (pump['group'] == '补水泵2') {
          expect(
            (display.first['bindings'] as Map).containsKey(pump['id']),
            false,
          );
        }
      }
    },
  );

  testWidgets(
    'pump layout changes only the draft until save, cancel and repeat preserve existing rows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = OverviewApi();
      final cols = legacyColumns();
      final tank = cols.singleWhere((c) => c['name'] == '水箱水位')['id'];
      api.config = {
        'revision': 1,
        'columns': cols,
        'rows': [
          {
            'id': 'area',
            'name': '中心站',
            'station': 'A',
            'bindings': {tank: 'tank1'},
            'additional': {
              'columns': [tank],
              'bindings': {tank: 'tank2'},
            },
          },
        ],
      };
      final original = jsonEncode(api.config);
      final originalRows = jsonEncode(api.config['rows']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: const {},
              live: const {},
              online: true,
              canEdit: true,
              stations: const ['A'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补水双泵布局'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 0);
      expect(jsonEncode(api.config), original);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.config), original);
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补水双泵布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 1);
      expect(jsonEncode(api.config['rows']), originalRows);
      final saved = jsonEncode(api.config['columns']);
      expect((api.config['columns'] as List).length, 33);
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补水双泵布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.config['columns']), saved);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pump1 valid zero is kept and unbound pump2 uses dashes without fallback',
    (tester) async {
      final api = OverviewApi()
        ..config = {
          'revision': 1,
          'columns': [
            for (final (i, c) in overviewMakeupPumpColumns.indexed)
              {...c, 'id': 'p$i'},
          ],
          'rows': [
            {
              'id': 'a',
              'name': '中心站',
              'station': 'A',
              'bindings': {'p0': 'zero', 'p1': 'frequency'},
            },
          ],
        };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              online: true,
              definitions: const {
                'zero': {
                  'id': 'zero',
                  'name': '补水电流',
                  'station': 'A',
                  'unit': 'A',
                },
                'frequency': {
                  'id': 'frequency',
                  'name': '补水频率',
                  'station': 'A',
                  'unit': 'Hz',
                },
              },
              live: const {
                'zero': {'value': 0, 'quality': 'good'},
                'frequency': {'value': 42, 'quality': 'good'},
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0.0'), findsOneWidget);
      expect(find.text('42.0'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wider electricity cells align headers and merged spans after reordering',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final columns = <Json>[
        {'id': 'power', 'group': '电能', 'name': '电能'},
        {'id': 'pump', 'group': '补水泵1', 'name': '电流'},
        {'id': 'tank', 'group': '补水水箱', 'name': '水位'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewTable(
              columns: columns,
              rows: [
                for (var i = 0; i < 2; i++)
                  {
                    'id': 'r$i',
                    'site': '中心所',
                    'name': '中心站',
                    'area': '区$i',
                    'bindings': {'power': 'e', 'pump': 'p', 'tank': 't$i'},
                  },
              ],
              reading: (_, c) => Text('value-${c['id']}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final power = tester.getRect(
        find.byKey(const ValueKey('merged-r0-power')),
      );
      final pump = tester.getRect(find.byKey(const ValueKey('merged-r0-pump')));
      expect(power.left, closeTo(216, .01));
      expect(power.width / pump.width, closeTo(1.3, .0001));
      expect(power.right, closeTo(pump.left, .01));
      expect(power.height, 52);
      expect(
        tester
            .getCenter(
              find
                  .ancestor(
                    of: find.byTooltip('电能'),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .dx,
        closeTo(power.center.dx, .01),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
