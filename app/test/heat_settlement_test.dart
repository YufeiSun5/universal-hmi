import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/features/external_data/heat_settlement.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/platform/settlement_price.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'external_data_test.dart' show ExternalApi;

class SettlementApi extends ExternalApi implements PersonalPreferenceIdentity {
  @override
  String preferenceServer = 'https://example.test:9090';
  @override
  String preferenceUser = 'alice';
  Json? last;
  String? queryPath;
  Completer<Json>? delayed;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/query')) {
      queryPath = path;
      last = body as Json;
      if (delayed != null) return delayed!.future;
      return result;
    }
    return super.request(method, path, body: body, query: query);
  }

  Json get result => {
    'heat_settlement': {
      'mode': last?['mode'],
      'from': '2026-11-05',
      'to': '2026-11-05',
      'as_of': '2026-11-05T12:00:00+08:00',
      'unit_price': last?['unit_price'],
      'incomplete': 1,
      'rows': [
        {
          'period': '2026-11-05',
          'name': '北站',
          'heat': '0.000000000000',
          'amount': '0.00',
          'status': '截至当前统计',
        },
        {
          'period': '2026-11-05',
          'name': '中心站',
          'heat': null,
          'amount': null,
          'status': '缺数（1/1）',
        },
      ],
    },
  };
}

const screen = {
  'id': 'energy/settlement',
  'query_id': 'energy',
  'kind': 'settlement',
  'name': '热量结算',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'local price isolates account and server, supports zero and clearing',
    () async {
      await saveSettlementPrice('a', 'alice', '25.123456');
      await saveSettlementPrice('a', 'bob', '0');
      expect(await loadSettlementPrice('a', 'alice'), '25.123456');
      expect(await loadSettlementPrice('a', 'bob'), '0');
      expect(await loadSettlementPrice('b', 'alice'), isNull);
      await saveSettlementPrice('a', 'alice', '');
      expect(await loadSettlementPrice('a', 'alice'), isNull);
      expect(await loadSettlementPrice('a', 'bob'), '0');
    },
  );
  test('CSV projection keeps null distinct from zero and exact decimals', () {
    final rows = settlementCells({
      'unit_price': '2.120000',
      'incomplete': 1,
      'rows': [
        {
          'period': 'x',
          'name': '北站',
          'heat': '12345678901234567890.123456780000',
          'amount': '26172839270617283927.06',
          'status': '完整',
        },
        {
          'period': 'x',
          'name': '中心站',
          'heat': null,
          'amount': null,
          'status': '缺数',
        },
      ],
    });
    expect(rows[0][2], '12345678901234567890.12345678');
    expect(rows[0][3], '2.12');
    expect(rows[1][2], '—');
    expect(rows.last[4], '—');
    expect(settlementNumber('0.00000000'), '0');
  });
  for (final size in [
    const Size(1440, 900),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('settlement query, remember, stale result and layout $size', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.reset);
      final api = SettlementApi();
      await saveSettlementPrice(
        api.preferenceServer,
        api.preferenceUser,
        '25.12',
      );
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: HeatSettlementQuery(api: api, screen: screen),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<TextField>(find.byKey(const Key('settlement-price')))
            .controller!
            .text,
        '25.12',
      );
      await t.tap(find.text('生成报表'));
      await t.pumpAndSettle();
      expect(api.queryPath, '/api/v1/external/screens/energy/query');
      expect(api.last!['mode'], 'settlement_daily');
      expect(api.last!['unit_price'], '25.12');
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('北站'), findsOneWidget);
      expect(t.takeException(), isNull);
      // Editing any input retires the displayed/exportable result immediately.
      final field = find.byKey(const Key('settlement-price'));
      await t.ensureVisible(field);
      await t.enterText(field, '30');
      await t.pumpAndSettle();
      expect(find.text('北站'), findsNothing);
      api.delayed = Completer<Json>();
      await t.tap(find.text('生成报表'));
      await t.pump();
      await t.ensureVisible(field);
      await t.enterText(field, '40');
      await t.pump();
      api.delayed!.complete(api.result);
      await t.pumpAndSettle();
      expect(find.text('北站'), findsNothing);
      expect(
        await loadSettlementPrice(api.preferenceServer, api.preferenceUser),
        '25.12',
      );
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
    'settlement entry uses existing energy authorization without new screen',
    (t) async {
      final api = SettlementApi();
      final catalog = ExternalCatalog(api, canDevelop: false)
        ..loaded = true
        ..screens = [
          {'id': 'energy', 'kind': 'energy', 'name': '能耗'},
        ];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EnergyWorkspace(catalog: catalog)),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('热量结算'));
      await t.pumpAndSettle();
      expect(find.byType(HeatSettlementQuery), findsOneWidget);
      expect(catalog.screens.length, 1);
      catalog.screens = [];
      catalog.notifyListeners();
      await t.pumpAndSettle();
      expect(find.byType(HeatSettlementQuery), findsNothing);
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
}
