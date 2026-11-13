import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'live_overview_test.dart' show OverviewApi, definitions, live;

class ControlApi extends OverviewApi {
  ControlApi() {
    config['control'] = {'enabled': true, 'base_url': 'http://127.0.0.1:8004'};
  }
  bool controlFail = false;
  Completer<Json>? pending;
  int reads = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '$overviewPath/control-status') {
      expect(method, 'GET');
      reads++;
      if (pending != null) return pending!.future;
      if (controlFail) throw Exception('offline');
      return {
        'revision': 1,
        'rows': {
          'a': {'active': true, 'label': '已接管'},
          'b': {'active': false, 'label': '未接管'},
        },
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  final columns = <Json>[
    {'id': 't', 'group': '一次网', 'name': '温度', 'decimals': 1},
  ];
  Json row(String id, String? point) => {
    'id': id,
    'name': '站',
    'station': id,
    'area': id,
    'bindings': {'t': ?point},
  };
  test('measurement ranges follow visible order and stable identity only', () {
    final rows = [
      row('a', 'p'),
      row('b', 'p'),
      row('c', 'q'),
      row('d', null),
      row('e', null),
      row('f', 'p'),
    ];
    expect(overviewMeasurementSpans(rows, columns), [
      (start: 0, end: 2, column: 0),
    ]);
    expect(overviewMeasurementSpans([rows[0], rows[1], rows[5]], columns), [
      (start: 0, end: 3, column: 0),
    ]);
    expect(
      overviewMeasurementSpans([rows[0], rows[2], rows[5]], columns),
      isEmpty,
    );
  });
  test(
    'merge updates imported identities and clears missing standard bindings without losing custom data',
    () {
      final custom = {
        'id': 'custom',
        'group': '自定义',
        'name': '备注',
        'decimals': 0,
      };
      final input = OverviewImport(
        columns,
        [row('a', null), row('new', 'p')],
        {'point_id': 'outdoor'},
        [],
        control: {'enabled': false, 'base_url': 'http://172.16.1.7:8004'},
      );
      final oldRow = {
        ...row('a', 'old'),
        'bindings': {'t': 'old', 'custom': 'private'},
      };
      final untouched = row('other', 'q');
      final result = input.merge(
        [custom, ...columns],
        [oldRow, untouched],
        input.rows,
      );
      expect(result.columns, [custom, ...columns]);
      expect(result.rows[0]['bindings'], {'custom': 'private'});
      expect(result.rows[1], untouched);
      expect(result.rows[2]['id'], 'new');
      expect(oldRow['bindings'], {'t': 'old', 'custom': 'private'});
      final repeat = input.merge(result.columns, result.rows, input.rows);
      expect(repeat.columns, result.columns);
      expect(repeat.rows, result.rows);
    },
  );
  test(
    'new valve column is inserted beside its imported neighbor and stays idempotent',
    () {
      Json column(String id) => {
        'id': id,
        'group': '一次网',
        'name': id,
        'decimals': 1,
      };
      final central = column('central'),
          local = column('local'),
          next = column('next'),
          custom = column('custom');
      final input = OverviewImport([central, local, next], [], {}, []);
      final merged = input.merge([custom, central, next], [], []);
      expect(merged.columns.map((c) => c['id']), [
        'custom',
        'central',
        'local',
        'next',
      ]);
      expect(input.merge(merged.columns, [], []).columns, merged.columns);
      expect(input.merge([custom, next], [], []).columns.map((c) => c['id']), [
        'custom',
        'central',
        'local',
        'next',
      ]);
    },
  );
  testWidgets(
    'merged readings retain one visible center and separate area status',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewTable(
              columns: columns,
              rows: [row('a', 'p'), row('b', 'p'), row('c', 'q')],
              units: const {},
              showControl: true,
              controlStates: const {
                'a': {'active': true, 'label': '已接管'},
                'b': {'active': false, 'label': '未接管'},
              },
              reading: (r, c) =>
                  Text((r['bindings'] as Map)['t'] == 'p' ? '0' : '0'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('merged-a-t')), findsOneWidget);
      expect(find.byType(OverviewControlArea), findsNWidgets(3));
      final merged = tester.getSize(find.byKey(const ValueKey('merged-a-t')));
      expect(merged.height, 52);
      expect(find.byTooltip('已接管'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'status failure clears green without erasing values and late response is ignored after offline',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = ControlApi();
      Widget app(bool online) => MaterialApp(
        home: Scaffold(
          body: LiveOverview(
            api: api,
            definitions: definitions,
            live: live,
            online: online,
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.byTooltip('已接管'), findsOneWidget);
      final tableBefore = tester.state(find.byType(OverviewTable));
      api.controlFail = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byTooltip('已接管'), findsNothing);
      expect(tester.state(find.byType(OverviewTable)), same(tableBefore));
      expect(find.text('62.6'), findsOneWidget);
      api.controlFail = false;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byTooltip('已接管'), findsOneWidget);
      api.pending = Completer<Json>();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(app(false));
      expect(find.byTooltip('已接管'), findsNothing);
      api.pending!.complete({
        'revision': 1,
        'rows': {
          'a': {'active': true, 'label': '已接管'},
        },
      });
      await tester.pump();
      expect(find.byTooltip('已接管'), findsNothing);
      expect(api.saveCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
