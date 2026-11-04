import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/comparison.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class CompareApi extends FakeApi {
  Json? input;
  Completer<Json>? pending;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'code': '01-001', 'name': '中心站'},
        ],
      };
    }
    if (path.endsWith('/query')) {
      input = Map<String, dynamic>.from(body as Map);
      if (pending != null) return pending!.future;
      return {
        'comparisons': [
          {
            '整站编码': '01-001',
            '甲方站名': '中心站',
            '指标': '水',
            '本期日用量': '0.00000000',
            '历史日用量折算': null,
            '变化百分比': '12.3400',
            '对比状态': '新站无历史数据',
            '参与对比天数': '0',
            '选择天数': '1',
            '汇总状态': '无可比日期',
          },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  for (final width in [420.0, 1440.0]) {
    testWidgets(
      'comparison inline windows and stale result protection at $width',
      (t) async {
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final api = CompareApi();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComparisonQuery(
                api: api,
                screen: {'id': 'compare', 'name': '同期对比'},
                autoQuery: false,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final query = find.text('查询对比');
        await t.ensureVisible(query);
        await t.tap(query);
        await t.pumpAndSettle();
        expect(api.input!['comparison_type'], '明细');
        expect(api.input!['station'], '');
        expect(find.text('0.00000000'), findsOneWidget);
        expect(find.text('站点'), findsOneWidget);
        expect(find.text('往年站名'), findsOneWidget);
        expect(find.text('整站编码'), findsNothing);
        expect(find.text('甲方站名'), findsNothing);
        expect(find.text('01-001'), findsNothing);
        final old = api.input!['history_from'] as String;
        final shift = find.byTooltip('历史窗口前移一天');
        await t.ensureVisible(shift);
        await t.tap(shift);
        await t.pumpAndSettle();
        expect(find.text('0.00000000'), findsNothing);
        api.pending = Completer<Json>();
        await t.ensureVisible(query);
        await t.tap(query);
        await t.pump();
        expect(
          api.input!['history_from'],
          DateTime.parse(old)
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10),
        );
        await t.ensureVisible(shift);
        await t.tap(shift);
        await t.pump();
        api.pending!.complete({
          'comparisons': [
            {'本期日用量': '999-stale'},
          ],
        });
        await t.pumpAndSettle();
        expect(find.text('999-stale'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
