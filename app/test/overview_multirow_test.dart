import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/layout.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'live_overview_test.dart' show OverviewApi;

final columns = <Json>[
  {'id': 'heat', 'group': '一次网', 'name': '累计热量', 'decimals': 1},
  {'id': 'supply', 'group': '二次网', 'name': '二网供水温度', 'decimals': 1},
  {'id': 'return', 'group': '二次网', 'name': '二网回水温度', 'decimals': 1},
  {'id': 'tank', 'group': '补水水箱', 'name': '水箱水位', 'decimals': 0},
  {'id': 'makeup', 'group': '补水水箱', 'name': '补水流量', 'decimals': 1},
];
Json zone(
  String id, {
  List<String> split = const [],
  Json second = const {},
}) => {
  'id': id,
  'site': '中心所',
  'name': '中心站',
  'area': id,
  'station': 'A',
  'bindings': {'heat': 'shared', 'supply': 's1', 'return': 'r1', 'tank': 't1'},
  if (split.isNotEmpty) 'additional': {'columns': split, 'bindings': second},
};
final defs = <String, Json>{
  for (final id in ['shared', 's1', 's2', 'r1', 'r2', 't1', 't2'])
    id: {
      'id': id,
      'name': id,
      'station': 'A',
      'unit': id.startsWith('t') ? 'mm' : '℃',
    },
};

void main() {
  test(
    'legacy rows stay single; tank-only, secondary-only and both split only selected cells',
    () {
      final legacy = zone('legacy');
      final tank = zone('tank', split: ['tank'], second: {'tank': 't2'});
      final secondary = zone(
        'secondary',
        split: ['supply', 'return'],
        second: {'supply': 's2'},
      );
      final both = zone(
        'both',
        split: ['tank', 'supply', 'return'],
        second: {'tank': 't2', 'supply': 's2', 'return': 'r2'},
      );
      final original = jsonEncode([legacy, tank, secondary, both]);
      final rows = overviewDisplayRows([
        legacy,
        tank,
        secondary,
        both,
      ], columns);
      expect(rows, hasLength(7));
      expect(rows[0]['bindings'], legacy['bindings']);
      expect(rows[2]['bindings'], {
        'heat': 'shared',
        'supply': 's1',
        'return': 'r1',
        'tank': 't2',
      });
      expect(rows[4]['bindings'], {
        'heat': 'shared',
        'tank': 't1',
        'supply': 's2',
      });
      expect((rows[4]['bindings'] as Map).containsKey('return'), isFalse);
      expect(rows[6]['bindings'], {
        'heat': 'shared',
        'tank': 't2',
        'supply': 's2',
        'return': 'r2',
      });
      expect(jsonEncode([legacy, tank, secondary, both]), original);
      expect(overviewDisplayRows([both], [columns.first]), hasLength(1));
      expect(overviewPointIDs([both], columns).toSet(), {
        'shared',
        's1',
        's2',
        'r1',
        'r2',
        't1',
        't2',
      });
    },
  );

  test(
    'shared columns span additional rows; split columns never merge even with identical point IDs',
    () {
      final rows = overviewDisplayRows([
        zone('first', split: ['tank'], second: {'tank': 't1'}),
        zone('second'),
        zone('third', split: ['supply', 'return'], second: {}),
      ], columns);
      final spans = overviewMeasurementSpans(rows, columns);
      expect(spans, contains((start: 0, end: 5, column: 0)));
      expect(spans, contains((start: 0, end: 3, column: 1)));
      expect(spans.where((s) => s.column == 3), [
        (start: 2, end: 5, column: 3),
      ]);
      // Shared missing values merge only within a zone, not across unrelated zones.
      expect(spans.where((s) => s.column == 4), [
        (start: 0, end: 2, column: 4),
        (start: 3, end: 5, column: 4),
      ]);
    },
  );

  test(
    'additional bindings round trip, resolve exact paths and survive old-file merges',
    () {
      final current = zone('a', split: ['tank'], second: {'tank': 't2'});
      final imported = OverviewImport.decode(
        encodeOverview(columns, [current], {}),
        defs,
      );
      expect(imported.rows.single, current);
      final old = OverviewImport.decode(
        encodeOverview(columns, [zone('a')], {}),
        defs,
      );
      expect(
        old.merge(columns, [current], old.rows).rows.single['additional'],
        current['additional'],
      );
      final byPath = zone(
        'b',
        split: ['tank'],
        second: {
          'tank': {'source_id': 'io', 'source_path': 'level2'},
        },
      );
      final pathDefs = {
        ...defs,
        't2': {...defs['t2']!, 'source_id': 'io', 'source_path': 'level2'},
      };
      final resolved = OverviewImport.decode(
        encodeOverview(columns, [byPath], {}),
        pathDefs,
      );
      expect(resolved.rows.single['additional'], {
        'columns': ['tank'],
        'bindings': {'tank': 't2'},
      });
      final ambiguous = OverviewImport.decode(
        encodeOverview(columns, [byPath], {}),
        {
          ...pathDefs,
          'duplicate': {'source_id': 'io', 'source_path': 'level2'},
        },
      );
      expect(ambiguous.missing, hasLength(1));
      expect((ambiguous.rows.single['additional'] as Map)['bindings'], isEmpty);
    },
  );

  test(
    'new file merge preserves custom split columns and can clear standard additional cells',
    () {
      final old = zone(
        'a',
        split: ['tank', 'custom'],
        second: {'tank': 't2', 'custom': 'r2'},
      );
      final incoming = zone('a')
        ..['additional'] = {
          'columns': <String>[],
          'bindings': <String, dynamic>{},
        };
      final data = OverviewImport(columns, [incoming], {}, []);
      final result = data.merge(
        [
          ...columns,
          {'id': 'custom'},
        ],
        [old],
        data.rows,
      );
      expect(result.rows.single['additional'], {
        'columns': ['custom'],
        'bindings': {'custom': 'r2'},
      });
      expect(old['additional'], {
        'columns': ['tank', 'custom'],
        'bindings': {'tank': 't2', 'custom': 'r2'},
      });
    },
  );

  test('invalid additional data is rejected before replacing a draft', () {
    for (final extra in [
      1,
      {
        'columns': ['tank', 'tank'],
        'bindings': {},
      },
      {
        'columns': ['missing'],
        'bindings': {},
      },
      {
        'columns': ['tank'],
        'bindings': {'supply': 's2'},
      },
      {
        'columns': ['tank'],
        'bindings': {'tank': 'stale'},
      },
      {
        'columns': ['tank'],
        'bindings': [],
      },
    ]) {
      expect(
        () => OverviewImport.decode(
          encodeOverview(columns, [zone('a')..['additional'] = extra], {}),
          defs,
        ),
        throwsFormatException,
      );
    }
  });

  testWidgets(
    'both equipment rows share zone label, hover and control state while first equipment remains intact',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [
        zone(
          'a',
          split: ['tank', 'supply', 'return'],
          second: {'tank': 't2', 'supply': 's2'},
        ),
        zone('b'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewTable(
              columns: columns,
              rows: rows,
              showControl: true,
              controlStates: const {
                'a': {'active': true, 'label': '已接管'},
              },
              reading: (row, col) =>
                  Text('${(row['bindings'] as Map)[col['id']] ?? '—'}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('a'), findsOneWidget);
      expect(find.text('②'), findsNWidgets(2));
      expect(find.text('t2'), findsOneWidget);
      expect(find.text('s2'), findsOneWidget);
      expect(find.byTooltip('已接管'), findsNWidgets(2));
      expect(
        tester.getSize(find.byKey(const ValueKey('merged-a-heat'))).height,
        78,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('a::2'))));
      await tester.pump();
      for (final id in ['a', 'a::2']) {
        final region = tester.widget<MouseRegion>(find.byKey(ValueKey(id)));
        expect((region.child as ColoredBox).color, const Color(0xffdaf0ff));
      }
      final other = tester.widget<MouseRegion>(find.byKey(const ValueKey('b')));
      expect((other.child as ColoredBox).color, isNot(const Color(0xffdaf0ff)));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor explicitly enables both presets and saves without replacing legacy bindings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = OverviewApi()
        ..config = {
          'revision': 1,
          'columns': columns,
          'rows': [zone('a')],
        };
      final original = jsonEncode(
        (api.config['rows'] as List).single['bindings'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: defs,
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
      await tester.tap(find.text('区内多设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双水箱'));
      await tester.tap(find.text('两套二网'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 0);
      expect(find.text('第二组未绑定'), findsNWidgets(3));
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      final saved = objects(api.config['rows']).single;
      expect(jsonEncode(saved['bindings']), original);
      expect(overviewSplitColumns(saved), {'tank', 'supply', 'return'});
      expect((saved['additional'] as Map)['bindings'], isEmpty);
      expect(api.saveCount, 1);
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('区内多设备'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(FilterChip, '双水箱').evaluate().single.widget,
        isA<FilterChip>().having((w) => w.selected, 'selected', true),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'additional points are subscribed and phone cards show the second value with bad quality preserved',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = OverviewApi()
        ..config = {
          'revision': 1,
          'columns': [columns[3]],
          'rows': [
            zone('a', split: ['tank'], second: {'tank': 't2'}),
          ],
        };
      Set<String> subscribed = {};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: defs,
              androidClient: true,
              online: true,
              live: const {
                't1': {'value': 1800, 'quality': 'good'},
                't2': {'value': 1900, 'quality': 'bad'},
              },
              onSubscriptionChanged: (ids) => subscribed = ids,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(subscribed, {'t1', 't2'});
      expect(find.text('1800 mm'), findsOneWidget);
      expect(find.text('— 坏质量'), findsOneWidget);
      expect(find.text('1900 mm'), findsNothing);
      expect(find.text('②'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
