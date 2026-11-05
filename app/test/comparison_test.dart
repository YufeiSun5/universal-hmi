import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/comparison.dart';
import 'package:universal_hmi/features/external_data/comparison_charts.dart';
import 'package:universal_hmi/shared/date_time_field.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class CompareApi extends FakeApi {
  Json? input;
  Completer<Json>? pending;
  final comparisonRequests = <Json>[];
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
      comparisonRequests.add(input!);
      if (pending != null) return pending!.future;
      if (input!['comparison_type'] == '明细') {
        return {
          'comparisons': [
            for (final metric in ['水', '电', '热'])
              for (var i = 0; i < 3; i++)
                {
                  '整站编码': '01-001',
                  '指标': metric,
                  '单位': metric == '热'
                      ? 'GJ'
                      : metric == '水'
                      ? 't'
                      : 'kWh',
                  '本期开始':
                      '2026-11-04T${(8 + i).toString().padLeft(2, '0')}:00:00+08:00',
                  '本期结束':
                      '2026-11-04T${(9 + i).toString().padLeft(2, '0')}:00:00+08:00',
                  '历史开始':
                      '2025-11-27T${(8 + i).toString().padLeft(2, '0')}:00:00+08:00',
                  '历史结束':
                      '2025-11-27T${(9 + i).toString().padLeft(2, '0')}:00:00+08:00',
                  '本期用量': i == 1 ? null : '0',
                  '历史折算用量': metric == '电' ? null : '12.25',
                  '本期平均气温': i == 1 ? null : '13.24',
                  '历史整点气温': '0.97',
                  '本期状态': i == 1 ? '映射变更' : '有效',
                  '历史状态': '有效',
                },
          ],
        };
      }
      return {
        'comparisons': [
          for (final metric in ['水', '电', '热'])
            {
              '整站编码': '01-001',
              '指标': metric,
              '单位': metric == '热'
                  ? 'GJ'
                  : metric == '水'
                  ? 't'
                  : 'kWh',
              '本期开始时间': '2026-11-04T00:00:00+08:00',
              '本期结束时间': '2026-11-04T21:10:20.471+08:00',
              '历史开始时间': '2025-11-27T00:00:00+08:00',
              '历史结束时间': '2025-11-27T21:10:20.471+08:00',
              '选择秒数': '76220.471',
              '用量可比秒数': metric == '电' ? '0' : '76220.471',
              '气温可比秒数': '72620.471',
              '气温状态': '气温不完整',
              '本期配对平均气温': '13.23679692983539',
              '历史配对平均气温': '0.9736826617387264',
              '本期有效秒数': '76220.471',
              '历史有效秒数': metric == '电' ? '0' : '76220.471',
              '本期有效用量小计': metric == '电'
                  ? '0'
                  : metric == '热'
                  ? '393'
                  : '980',
              '历史有效用量小计': metric == '电'
                  ? null
                  : metric == '热'
                  ? '933.06'
                  : '156.99',
              '本期配对用量': metric == '电'
                  ? null
                  : metric == '热'
                  ? '393'
                  : '980',
              '历史配对用量': metric == '电'
                  ? null
                  : metric == '热'
                  ? '933.06'
                  : '156.99',
              '用量差值': metric == '电'
                  ? null
                  : metric == '热'
                  ? '-540.06'
                  : '823.01',
              '用量变化百分比': metric == '电'
                  ? null
                  : metric == '热'
                  ? '-57.88052215291621'
                  : '524.243582393783',
              '用量状态': metric == '电' ? '无可比用量' : '全窗口可比',
            },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  for (final width in [420.0, 1440.0]) {
    testWidgets('curve tooltip follows pointer and avoids edges at $width', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final response = await CompareApi().request(
        'POST',
        '/query',
        body: {'comparison_type': '明细'},
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ComparisonCharts(
                rows: objects(response['comparisons']),
                daily: false,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final plot = find.byKey(const ValueKey('comparison-plot-水'));
      await t.ensureVisible(plot);
      await t.pumpAndSettle();
      final area = t.getRect(plot),
          pointer = Offset(area.right - 20, area.bottom - 35);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(pointer);
      await t.pump();
      final popup = find.byKey(const ValueKey('comparison-pointer-tooltip'));
      expect(popup, findsOneWidget);
      final box = t.getRect(popup);
      expect(box.left, greaterThanOrEqualTo(8));
      expect(box.right, lessThanOrEqualTo(width - 8));
      expect(box.top, greaterThanOrEqualTo(8));
      expect(box.bottom, lessThanOrEqualTo(992));
      expect((box.right - pointer.dx).abs(), lessThan(330));
      expect(
        find.descendant(of: popup, matching: find.text('0.00 t')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: popup, matching: find.text('12.25 t')),
        findsOneWidget,
      );
      // The missing middle fragment stays missing, not zero.
      await mouse.moveTo(
        Offset(area.left + 58 + (area.width - 74) / 3, area.center.dy),
      );
      await t.pump();
      expect(
        find.descendant(of: popup, matching: find.text('—')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await t.pump();
      expect(popup, findsNothing);
      expect(t.takeException(), isNull);
      await mouse.removePointer();
    });
  }
  test(
    'Beijing input preserves explicit offsets and appends +8 to wall time',
    () {
      expect(beijingIso('2026-11-04T08:15'), '2026-11-04T08:15:00+08:00');
      expect(beijingIso('2026-11-04T00:15:00Z'), '2026-11-04T00:15:00Z');
      expect(clock('2026-11-03T16:10:00Z'), '2026-11-04 00:10:00');
      expect(
        beijingWall(
          '2026-11-04T08:15',
        )!.difference(beijingWall('2026-11-04T00:00')!),
        const Duration(hours: 8, minutes: 15),
      );
      expect(
        beijingStamp(
          beijingWall(
            '2026-11-04T08:15:20.471+08:00',
          )!.add(const Duration(hours: 1)),
        ),
        '2026-11-04T09:15:20.471',
      );
    },
  );
  for (final width in [420.0, 1440.0]) {
    testWidgets(
      'paired summary, automatic curves and latest response at $width',
      (t) async {
        t.view.physicalSize = Size(width, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final api = CompareApi();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComparisonQuery(
                api: api,
                screen: {'id': 'comparison', 'name': '同期对比'},
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
        expect(api.comparisonRequests.first['comparison_type'], '汇总');
        expect(api.input!['mode'], 'sliding');
        expect(api.input!['station'], '01-001');
        expect(api.input!['from'], endsWith('+08:00'));
        expect(api.comparisonRequests.first['to'], '');
        expect(api.comparisonRequests.length, 2);
        expect(find.textContaining('13.24℃'), findsOneWidget);
        expect(find.textContaining('1.00 小时'), findsOneWidget);
        expect(find.textContaining('-57.88%'), findsOneWidget);
        expect(find.textContaining('524.24%'), findsOneWidget);
        expect(find.textContaining('本期独立小计 0.00'), findsOneWidget);
        expect(find.text('01-001'), findsNothing);
        expect(find.text('展开曲线'), findsNothing);
        expect(api.input!['to'], '2026-11-04T21:10:20.471+08:00');
        expect(api.input!['history_to'], '2025-11-27T21:10:20.471+08:00');
        expect(api.input!['comparison_type'], '明细');
        expect(find.text('气温 · ℃'), findsOneWidget);
        expect(t.takeException(), isNull);
        // A delayed summary cannot replace results after changing the window.
        api.pending = Completer<Json>();
        await t.ensureVisible(query);
        await t.tap(query);
        await t.pump();
        final shift = find.byTooltip('历史窗口前移一小时');
        await t.ensureVisible(shift);
        await t.tap(shift);
        await t.pump();
        api.pending!.complete({
          'comparisons': [
            {'整站编码': '01-001', '用量状态': 'stale-marker'},
          ],
        });
        api.pending = null;
        await t.pumpAndSettle();
        expect(find.textContaining('stale-marker'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('date input offers calendar and 24-hour clock', (t) async {
    final controller = TextEditingController(text: '2026-11-04T08:15');
    addTearDown(controller.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DateTimeField(
            controller: controller,
            label: '开始',
            includeTime: true,
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('选择开始'));
    await t.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(controller.text, '2026-11-04T08:15');
  });
}
