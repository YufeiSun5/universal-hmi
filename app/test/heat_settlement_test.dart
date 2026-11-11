import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/heat_settlement.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'package:universal_hmi/shared/table.dart';
import 'external_data_test.dart' show ExternalApi;

class SettlementApi extends ExternalApi {
  Json prices = {
    'revision': 1,
    'can_edit': true,
    'items': <Json>[
      {'year': 2025, 'unit_price': '20.5'},
      {'year': 2026, 'unit_price': '25.12'},
    ],
  };
  Json? priceChange;
  bool conflict = false;

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
    if (path.endsWith('/heat-prices')) {
      if (method == 'POST') {
        priceChange = body as Json;
        if (conflict) throw StateError('配置已被修改，请刷新后重试');
        prices = {
          'revision': 2,
          'can_edit': true,
          'items': <Json>[
            {'year': 2025, 'unit_price': '20.5'},
            {
              'year': priceChange!['year'],
              'unit_price': priceChange!['unit_price'],
            },
          ],
        };
      }
      return prices;
    }
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
      'unit_price': '25.12',
      'incomplete': 1,
      'rows': [
        {
          'period': '2026-11-05',
          'name': '北站',
          'unit_price': '25.12',
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
  testWidgets(
    'short content area keeps report rows visible below the host header',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(844, 390);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 200,
                child: HeatSettlementQuery(
                  api: SettlementApi(),
                  screen: screen,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byType(DenseTable)).height,
        greaterThanOrEqualTo(100),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  test('CSV projection keeps null distinct from zero and exact decimals', () {
    final rows = settlementCells({
      'incomplete': 1,
      'rows': [
        {
          'period': 'x',
          'unit_price': '2.120000',
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
    expect(settlementHeaders, ['统计周期', '站点', '热量（GJ）', '单价（元/GJ）', '金额（元）']);
    expect(rows.every((r) => r.length == 5), isTrue);
    expect(
      rows.expand((r) => r).any((v) => v.contains('缺数') || v.contains('完整')),
      isFalse,
    );
  });
  for (final size in [
    const Size(1440, 900),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('settlement shared price, stale result and layout $size', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.reset);
      final api = SettlementApi();
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: HeatSettlementQuery(api: api, screen: screen),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('settlement-price')), findsNothing);
      expect(find.textContaining('25.12 元/GJ'), findsOneWidget);
      await t.tap(find.text('生成报表'));
      await t.pumpAndSettle();
      expect(api.queryPath, '/api/v1/external/screens/energy/query');
      expect(api.last!['mode'], 'settlement_daily');
      expect(api.last!.containsKey('unit_price'), isFalse);
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('北站'), findsOneWidget);
      expect(find.text('统计情况'), findsNothing);
      expect(find.textContaining('截至'), findsNothing);
      expect(find.textContaining('缺数'), findsNothing);
      expect(t.takeException(), isNull);
      // Editing any input retires the displayed/exportable result immediately.
      final field = find.descendant(
        of: find.byKey(const Key('settlement-date')),
        matching: find.byType(TextField),
      );
      await t.ensureVisible(field);
      await t.enterText(field, '2026-11-04');
      await t.pumpAndSettle();
      expect(find.text('北站'), findsNothing);
      api.delayed = Completer<Json>();
      await t.tap(find.text('生成报表'));
      await t.pump();
      await t.ensureVisible(field);
      await t.enterText(field, '2026-11-05');
      await t.pump();
      api.delayed!.complete(api.result);
      await t.pumpAndSettle();
      expect(find.text('北站'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'history curve, shared save and explicit conflict without overwrite',
    (t) async {
      final api = SettlementApi();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HeatSettlementQuery(api: api, screen: screen),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('历年价格'));
      await t.pumpAndSettle();
      expect(find.text('2025–2026 采暖季'), findsOneWidget);
      expect(find.text('2026–2027 采暖季'), findsOneWidget);
      expect(find.byKey(const Key('heat-price-value')), findsNothing);
      await t.tap(find.byTooltip('价格操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('补录 / 修改价格'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('heat-price-value')), '30.125');
      api.conflict = true;
      await t.tap(find.text('保存共享价格'));
      await t.pumpAndSettle();
      expect(find.textContaining('配置已被修改'), findsOneWidget);
      expect(api.prices['revision'], 1);
      api.conflict = false;
      await t.tap(find.text('保存共享价格'));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 300));
      expect(api.priceChange!['revision'], 1);
      expect(api.priceChange!['unit_price'], '30.125');
      expect(find.text('30.125 元/GJ'), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      expect(find.textContaining('30.125 元/GJ'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('readonly price history has no modification menu', (t) async {
    final api = SettlementApi()..prices['can_edit'] = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HeatSettlementQuery(api: api, screen: screen),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('历年价格'));
    await t.pumpAndSettle();
    expect(find.byTooltip('价格操作'), findsNothing);
    expect(find.textContaining('当前入口只读'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
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
