import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';
import 'workspace_test.dart' show FakeApi, launch;

class HistoryLayoutApi extends FakeApi {
  bool withJobs = false;
  String scope = '';
  String jobState = 'completed';
  bool rejectCancel = false;
  HistoryLayoutApi() {
    rows.add({...point('history-point', '供热站A'), 'name': '供热站一次侧供水温度长中文变量名称'});
  }
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (path == '/api/v1/jobs/layout-job/cancel') {
      if (rejectCancel) throw const PlatformRequestException(403, '无权取消此任务');
      jobState = 'cancelled';
      return Future.value({});
    }
    if (path == '/api/v1/history') {
      requests.add('$method $path ${query ?? {}}');
      return Future.value({
        'items': [
          for (var i = 0; i < 24; i++)
            {
              'point_id': 'history-point',
              'station': scope.isEmpty ? '供热站A' : scope,
              'name': '供热站一次侧供水温度长中文变量名称',
              'unit': '℃',
              'value': 40.0 + i,
              'quality': 'good',
              'version': 'v1',
              'source_time': DateTime.utc(2026, 11, 1, 0, i).toIso8601String(),
            },
        ],
        'stats': {'count': 24, 'min': 40, 'max': 63, 'mean': 51.5},
        'boundary': 1,
      });
    }
    if (path == '/api/v1/jobs' && withJobs) {
      return Future.value({
        'items': [
          {
            'id': 'layout-job',
            'state': jobState,
            'format': 'xlsx',
            'rows': 12,
            'station': scope,
          },
        ],
      });
    }
    return super.request(method, path, body: body, query: query);
  }
}

Finder filterField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> openPage(
  WidgetTester tester,
  HistoryLayoutApi api,
  int page,
  Size size,
) async {
  await launch(tester, api, size: size);
  final dynamic state = tester.state(find.byType(Workspace));
  if (api.scope.isNotEmpty) {
    state.switchStation(api.scope);
    await tester.pumpAndSettle();
  }
  state.navigate(page);
  await tester.pumpAndSettle();
  await tester.tap(find.text('筛选'));
  await tester.pumpAndSettle();
}

void expectVisible(WidgetTester tester, Finder finder, Size size) {
  expect(finder.hitTestable(), findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width));
  expect(rect.bottom, lessThanOrEqualTo(size.height));
}

void main() {
  for (final scope in ['', '供热站A']) {
    for (final page in [3, 4, 7]) {
      for (final size in [
        const Size(640, 480),
        const Size(900, 600),
        const Size(1440, 900),
      ]) {
        testWidgets(
          'history page $page scope $scope keeps filter actions visible at $size',
          (tester) async {
            final api = HistoryLayoutApi()..scope = scope;
            await openPage(tester, api, page, size);
            expectVisible(
              tester,
              find
                  .ancestor(
                    of: find.text('筛选'),
                    matching: find.byWidgetPredicate(
                      (widget) => widget is FilledButton,
                    ),
                  )
                  .first,
              size,
            );
            expectVisible(tester, find.widgetWithText(TextButton, '清除'), size);
            expect(tester.takeException(), isNull);
            await tester.enterText(
              filterField('开始时间 ISO（可选）'),
              '2026-10-31T23:59:59.123456+08:00',
            );
            await tester.enterText(
              filterField('结束时间 ISO（可选）'),
              '2026-11-01T23:59:59.123456+08:00',
            );
            await tester.tap(find.text('筛选'));
            await tester.pumpAndSettle();
            expect(
              api.requests.lastWhere(
                (r) => r.startsWith('GET /api/v1/history '),
              ),
              contains(
                'from: ${DateTime.parse('2026-10-31T23:59:59.123456+08:00').toUtc().millisecondsSinceEpoch}',
              ),
            );
            await tester.tap(find.text('清除'));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<TextField>(filterField('开始时间 ISO（可选）'))
                  .controller!
                  .text,
              isEmpty,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'report with completed jobs keeps filters accessible in a short window',
    (tester) async {
      final api = HistoryLayoutApi()
        ..withJobs = true
        ..scope = '供热站A';
      const size = Size(640, 480);
      await openPage(tester, api, 4, size);
      expectVisible(tester, find.byKey(const Key('report-jobs-open')), size);
      await tester.tap(find.text('样本明细'));
      await tester.pumpAndSettle();
      expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 24);
      expect(
        tester.getSize(find.byType(DenseTable)).height,
        greaterThanOrEqualTo(90),
      );
      await tester.tap(find.byKey(const Key('report-jobs-open')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('保存报表').hitTestable(), findsOneWidget);
      expect(find.byTooltip('删除任务和文件').hitTestable(), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expectVisible(
        tester,
        find
            .ancestor(
              of: find.text('筛选'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            )
            .first,
        size,
      );
      expectVisible(tester, find.widgetWithText(TextButton, '清除'), size);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('short report task dialog updates and survives resizing', (
    tester,
  ) async {
    final api = HistoryLayoutApi()
      ..withJobs = true
      ..scope = '供热站A'
      ..jobState = 'running';
    await openPage(tester, api, 4, const Size(640, 480));
    expect(find.textContaining('正在执行 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-jobs-open')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消任务').hitTestable(), findsOneWidget);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    api.jobState = 'completed';
    final dynamic state = tester.state(find.byType(Workspace));
    state.lastJobs = 0;
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();
    expect(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byTooltip('保存报表'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.byTooltip('取消任务'), findsNothing);
    tester.view.physicalSize = const Size(640, 480);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('导出任务 (1)'), findsOneWidget);
    expect(find.textContaining('正在执行'), findsNothing);
    state.lastJobs = 0;
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('task cancellation error stays visible inside the task dialog', (
    tester,
  ) async {
    final api = HistoryLayoutApi()
      ..withJobs = true
      ..scope = '供热站A'
      ..jobState = 'running'
      ..rejectCancel = true;
    await openPage(tester, api, 4, const Size(640, 480));
    final dynamic state = tester.state(find.byType(Workspace));
    state.error = '之前查询失败';
    state.openReportJobs();
    state.openReportJobs();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('report-jobs-error')), findsNothing);
    await tester.tap(find.byTooltip('取消任务'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('report-jobs-error')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('无权取消此任务'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('取消任务').hitTestable(), findsOneWidget);
    expect(api.jobState, 'running');
    final close = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
        .onPressed!;
    close();
    close();
    await tester.pumpAndSettle();
    expect(find.byType(Workspace), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'responsive filters preserve input controller, selection and IME state',
    (tester) async {
      final api = HistoryLayoutApi();
      api.rows.add({
        ...api.point('long-point', 'A'),
        'name': '供热站一次侧供水温度长中文变量名称',
      });
      await openPage(tester, api, 4, const Size(1440, 900));
      await tester.tap(find.byKey(const Key('history-point-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A / 供热站一次侧供水温度长中文变量名称'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextField>(filterField('最小值'))
          .controller!;
      const value = TextEditingValue(
        text: '30',
        selection: TextSelection(baseOffset: 0, extentOffset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      controller.value = value;
      await tester.pump();
      for (final size in [const Size(640, 480), const Size(1440, 900)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          identical(
            tester.widget<TextField>(filterField('最小值')).controller,
            controller,
          ),
          isTrue,
        );
        expect(controller.value, value);
        expectVisible(
          tester,
          find.byKey(const Key('history-point-select')),
          size,
        );
        expectVisible(
          tester,
          find
              .ancestor(
                of: find.text('筛选'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              )
              .first,
          size,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
