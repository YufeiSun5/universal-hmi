import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';
import 'history_workflow_test.dart' show HistoryWorkflowApi;
import 'workspace_test.dart' show launch;

class AuditHistoryApi extends HistoryWorkflowApi {
  bool rejectNext = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/history' && rejectNext) {
      rejectNext = false;
      throw Exception('temporary audit failure');
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'Out-of-picker-range date opens calendar and cancel preserves input',
    (tester) async {
      final api = AuditHistoryApi();
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('nav-4')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('history-from')),
        '1999-01-01 12:30:00',
      );
      await tester.tap(find.byTooltip('选择开始时间'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('history-from')))
            .controller!
            .text,
        '1999-01-01 12:30:00',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Failed refresh preserves frozen export boundary', (
    tester,
  ) async {
    final api = AuditHistoryApi();
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部时间'));
    await tester.pumpAndSettle();
    api.rejectNext = true;
    await tester.tap(find.byKey(const Key('history-query')));
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary audit failure'), findsOneWidget);
    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();
    final exports = api.exports;
    expect(exports, hasLength(1));
    expect(exports.single['before'], 9000);
    await tester.pumpWidget(const SizedBox());
  });
}
