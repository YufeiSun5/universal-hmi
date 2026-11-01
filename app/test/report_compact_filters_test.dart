import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/table.dart';
import 'history_filter_layout_test.dart'
    show HistoryLayoutApi, openPage, openCompactFilters, filterField;

void main() {
  testWidgets(
    'short report keeps export controls and four rows worth of viewport',
    (tester) async {
      final api = HistoryLayoutApi()
        ..withJobs = true
        ..scope = '供热站A';
      await openPage(tester, api, 4, const Size(640, 480));
      for (final label in ['导入 Excel / CSV', '导出 XLSX', '导出 CSV', '筛选 (0)']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      await tester.tap(find.text('样本明细'));
      await tester.pumpAndSettle();
      expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 24);
      expect(
        tester.getSize(find.byType(DenseTable)).height,
        greaterThanOrEqualTo(140),
      );
      expect(
        find.byKey(const Key('report-jobs-open')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancelled advanced edits preserve original IME and do not query',
    (tester) async {
      final api = HistoryLayoutApi()..scope = '供热站A';
      await openPage(tester, api, 4, const Size(640, 480));
      final dynamic state = tester.state(find.byType(Workspace));
      const before = TextEditingValue(
        text: '20',
        selection: TextSelection(baseOffset: 0, extentOffset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      state.min.value = before;
      final requests = api.requests
          .where((r) => r.startsWith('GET /api/v1/history '))
          .length;
      await openCompactFilters(tester);
      expect(
        tester.widget<TextField>(filterField('最小值')).controller!.value,
        before,
      );
      await tester.enterText(filterField('最小值'), '35');
      await tester.enterText(
        filterField('开始时间 ISO（可选）'),
        '2026-11-01T08:00:00+08:00',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.min.value, before);
      expect(state.from.text, isEmpty);
      expect(
        api.requests.where((r) => r.startsWith('GET /api/v1/history ')).length,
        requests,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('apply commits draft once, clear also requires apply', (
    tester,
  ) async {
    final api = HistoryLayoutApi()..scope = '供热站A';
    await openPage(tester, api, 4, const Size(640, 480));
    await openCompactFilters(tester);
    await tester.enterText(filterField('最小值'), '30');
    await tester.enterText(filterField('最大值'), '70');
    await tester.enterText(
      filterField('开始时间 ISO（可选）'),
      '2026-11-01T08:00:00+08:00',
    );
    final count = api.requests
        .where((r) => r.startsWith('GET /api/v1/history '))
        .length;
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(
      api.requests.where((r) => r.startsWith('GET /api/v1/history ')).length,
      count + 1,
    );
    expect(
      api.requests.lastWhere((r) => r.startsWith('GET /api/v1/history ')),
      contains('min: 30'),
    );
    expect(find.text('筛选 (3)'), findsOneWidget);
    await openCompactFilters(tester);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('筛选 (3)'), findsOneWidget);
    await openCompactFilters(tester);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('筛选 (0)'), findsOneWidget);
    expect(
      api.requests.lastWhere((r) => r.startsWith('GET /api/v1/history ')),
      isNot(contains('min:')),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'invalid date stays local and draft survives viewport expansion',
    (tester) async {
      final api = HistoryLayoutApi();
      await openPage(tester, api, 4, const Size(640, 480));
      await openCompactFilters(tester);
      await tester.enterText(filterField('开始时间 ISO（可选）'), '不是时间');
      final count = api.requests
          .where((r) => r.startsWith('GET /api/v1/history '))
          .length;
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 ISO 时间'), findsOneWidget);
      expect(
        api.requests.where((r) => r.startsWith('GET /api/v1/history ')).length,
        count,
      );
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final draftStart = find.descendant(
        of: dialog,
        matching: filterField('开始时间 ISO（可选）'),
      );
      expect(tester.widget<TextField>(draftStart).controller!.text, '不是时间');
      await tester.enterText(draftStart, '2026-11-01T00:00:00Z');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(filterField('开始时间 ISO（可选）')).controller!.text,
        '2026-11-01T00:00:00Z',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('nested variable selection remains a draft until apply', (
    tester,
  ) async {
    final api = HistoryLayoutApi()..scope = '供热站A';
    await openPage(tester, api, 4, const Size(640, 480));
    final dynamic state = tester.state(find.byType(Workspace));
    await openCompactFilters(tester);
    await tester.tap(find.byKey(const Key('history-draft-point-select')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(AlertDialog, '选择历史变量'),
        matching: find.text('供热站A / 供热站一次侧供水温度长中文变量名称'),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.historyPoint, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.historyPoint, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'repeated advanced callbacks neither pop workspace nor duplicate query',
    (tester) async {
      final api = HistoryLayoutApi();
      await openPage(tester, api, 4, const Size(640, 480));
      final dynamic state = tester.state(find.byType(Workspace));
      state.editReportFilters();
      state.editReportFilters();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final pick = tester
          .widget<OutlinedButton>(
            find.byKey(const Key('history-draft-point-select')),
          )
          .onPressed!;
      pick();
      pick();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '选择历史变量'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNWidgets(2));
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(AlertDialog, '选择历史变量'),
          matching: find.widgetWithText(TextButton, '取消'),
        ),
      );
      await tester.pumpAndSettle();
      final count = api.requests
          .where((r) => r.startsWith('GET /api/v1/history '))
          .length;
      final apply = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用'))
          .onPressed!;
      apply();
      apply();
      await tester.pumpAndSettle();
      expect(
        api.requests.where((r) => r.startsWith('GET /api/v1/history ')).length,
        count + 1,
      );
      expect(find.byType(Workspace), findsOneWidget);
      await openCompactFilters(tester);
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(
        api.requests.where((r) => r.startsWith('GET /api/v1/history ')).length,
        count + 1,
      );
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
