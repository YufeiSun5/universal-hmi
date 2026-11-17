import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/period_report.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'materials_test.dart' show MaterialsApi, host, sized;

void main() {
  testWidgets(
    'report queries month, filters export eligibility and clears failed results',
    (t) async {
      await sized(t, const Size(1440, 900));
      final api = MaterialsApi();
      api.responses['/api/v1/materials/reports'] = {
        'kind': 'inbound',
        'columns': ['序号', '入库时间', '名称'],
        'items': [
          {
            'document_id': 'd',
            'cells': ['1', '2026-11-16', '测试物料'],
          },
        ],
        'total': 1,
        'documents': 1,
        'known_amount': '12.50',
        'missing_prices': 0,
      };
      final session = MaterialsSession();
      addTearDown(session.dispose);
      await t.pumpWidget(
        host(
          MaterialPeriodReport(
            api: api,
            session: session,
            access: {'grants': api.permissions},
            onClearCategory: () {},
            onShowDirectory: () {},
            directoryHidden: false,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('测试物料'), findsOneWidget);
      final first = api.calls.last['query'] as Map;
      expect(first['kind'], 'inbound');
      expect(first['from'], isNotEmpty);
      expect(first['until'], isNotEmpty);
      expect(find.text('合并导出入库＋出库'), findsNothing);
      expect(find.text('导出入库'), findsOneWidget);
      await t.tap(find.text('出库明细'));
      await t.pumpAndSettle();
      expect((api.calls.last['query'] as Map)['kind'], 'outbound');
      expect(find.text('导出出库'), findsOneWidget);
      await t.tap(find.text('入库明细'));
      await t.pumpAndSettle();
      await t.tap(find.text('查看原单'));
      await t.pumpAndSettle();
      expect(
        api.calls.any((c) => c['path'] == '/api/v1/materials/documents/d'),
        isTrue,
      );
      await t.tap(find.byTooltip('返回列表'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextField, '料号／物料名称／规格／单号／领用方'),
        '测试',
      );
      await t.pump();
      expect(
        t
            .widget<OutlinedButton>(
              find
                  .ancestor(
                    of: find.text('导出入库'),
                    matching: find.byWidgetPredicate(
                      (w) => w is OutlinedButton,
                    ),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      api.intercept = (m, p, b) => Future.error(StateError('查询失败'));
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      expect(find.text('测试物料'), findsNothing);
      expect(find.textContaining('查询失败'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'inbound-only user gets report entry but no outbound or combined export',
    (t) async {
      await sized(t, const Size(1440, 900));
      final api = MaterialsApi()..permissions = {'materials_inbound': true};
      final session = MaterialsSession()..section = 'reports';
      addTearDown(session.dispose);
      await t.pumpWidget(host(MaterialsWorkspace(api: api, session: session)));
      await t.pumpAndSettle();
      expect(find.text('入库明细'), findsOneWidget);
      expect(find.text('出库明细'), findsNothing);
      expect(find.text('合并导出入库＋出库'), findsNothing);
      expect(
        api.calls.where((c) => c['path'] == '/api/v1/materials/reports'),
        isNotEmpty,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'category change ignores late previous query and narrow controls remain usable',
    (t) async {
      await sized(t, const Size(800, 900));
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final first = Completer<Map<String, dynamic>>();
      var calls = 0;
      api.intercept = (m, p, b) async {
        if (++calls == 1) return first.future;
        return {
          'columns': ['名称'],
          'items': [
            {
              'cells': ['新分类'],
            },
          ],
          'total': 1,
        };
      };
      Widget view(String id) => host(
        MaterialPeriodReport(
          api: api,
          session: session,
          access: {'grants': api.permissions},
          category: {'id': id, 'name': id},
          onClearCategory: () {},
          onShowDirectory: () {},
          directoryHidden: false,
        ),
      );
      await t.pumpWidget(view('old'));
      await t.pump();
      await t.pumpWidget(view('new'));
      await t.pumpAndSettle();
      first.complete({
        'columns': ['名称'],
        'items': [
          {
            'cells': ['旧分类'],
          },
        ],
        'total': 1,
      });
      await t.pumpAndSettle();
      expect(find.text('新分类'), findsOneWidget);
      expect(find.text('旧分类'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
