import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/layout.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/live_overview/visibility.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'live_overview_test.dart' show OverviewApi;

final columns = <Json>[
  {'id': 'p', 'group': '二次网', 'name': '二网循环泵出口压力', 'decimals': 2},
  {'id': 'm', 'group': '补水泵2', 'name': '补水泵2电流', 'decimals': 1},
  {'id': 'c', 'group': '循环泵', 'name': '循3电流', 'decimals': 1},
  {'id': 'f', 'group': '循环泵', 'name': '循3频率', 'decimals': 1},
  {'id': 'e', 'group': '电能', 'name': '电能', 'decimals': 1},
];

void main() {
  test(
    'desktop defaults hide only requested metrics and allocate all remaining width',
    () {
      final desktop = overviewClientColumns(columns, phone: false);
      expect(desktop.map((c) => c['id']), ['f', 'e']);
      expect(overviewClientColumns(columns, phone: true).length, 5);
      expect(
        overviewDesktopVisible({...columns.first, 'desktop_visible': true}),
        isTrue,
      );
      expect(overviewDesktopVisible({'name': '变压器电流', 'group': '电能'}), isTrue);
      final widths = overviewColumnWidths(desktop, 800);
      expect(widths.reduce((a, b) => a + b), closeTo(800, 0.001));
      expect(widths.last / widths.first, closeTo(1.3, 0.001));
      final imported = OverviewImport.decode(
        encodeOverview(columns, [], {}),
        {},
      );
      final merged = imported.merge(
        [
          {...columns.first, 'desktop_visible': true},
        ],
        [],
        [],
      );
      expect(merged.columns.first['desktop_visible'], isTrue);
    },
  );

  for (final phone in [false, true]) {
    testWidgets('desktop choice preserves dual device bindings phone=$phone', (
      t,
    ) async {
      t.view.physicalSize = Size(phone ? 390 : 1366, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = OverviewApi();
      api.config['columns'] = jsonDecode(jsonEncode(columns));
      api.config['rows'] = [
        {
          'id': 'r',
          'station': 'A',
          'name': '中心站',
          'area': '东南区',
          'bindings': {for (final c in columns) c['id']: c['id']},
          'additional': {
            'columns': ['m'],
            'bindings': {'m': 'm2'},
          },
        },
      ];
      Set<String> subscribed = {};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: {
                for (final c in columns)
                  c['id'] as String: <String, dynamic>{'id': c['id']},
                'm2': <String, dynamic>{'id': 'm2'},
              },
              live: const {},
              online: true,
              androidClient: phone,
              onSubscriptionChanged: (ids) => subscribed = ids,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(subscribed, phone ? {'p', 'm', 'c', 'f', 'e', 'm2'} : {'f', 'e'});
      expect(api.config['rows'][0]['additional']['bindings']['m'], 'm2');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'restore desktop column survives save and deletion requires confirmation',
    (t) async {
      t.view.physicalSize = const Size(1500, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = OverviewApi();
      api.config['columns'] = [columns.first];
      api.config['rows'] = [
        {
          'id': 'r',
          'station': 'A',
          'name': '中心站',
          'bindings': {'p': 'point'},
          'additional': {
            'columns': ['p'],
            'bindings': {'p': 'second'},
          },
        },
      ];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Json>(
                  context: context,
                  builder: (_) => OverviewEditor(
                    api: api,
                    config: api.config,
                    definitions: const {},
                    stations: const ['A'],
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('desktop-visible-p'));
      expect(t.widget<FilterChip>(toggle).selected, isFalse);
      await t.tap(toggle);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('移除'));
      await t.pumpAndSettle();
      expect(find.textContaining('影响全部终端'), findsOneWidget);
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存总览'));
      await t.pumpAndSettle();
      expect(api.config['columns'][0]['desktop_visible'], isTrue);
      expect(api.config['rows'][0]['bindings']['p'], 'point');
      expect(api.config['rows'][0]['additional']['bindings']['p'], 'second');
      expect(t.takeException(), isNull);
    },
  );
}
