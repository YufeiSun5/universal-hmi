import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/alarm_columns.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/reports.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'external_reports_test.dart' show ReportsApi;
import 'support/ui_lint.dart';

class LayoutApi extends ReportsApi {
  Json screen = {'id': 'alarm', 'kind': 'alarm', 'name': '报警历史', 'revision': 1};
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/screens')) {
      if (method == 'POST') {
        screen = {...body as Json, 'revision': 2};
        return screen;
      }
      return {
        'items': [screen],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('mobile alarm editor and query form geometry at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 760);
      addTearDown(tester.view.reset);
      final api = LayoutApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.25)),
            child: child!,
          ),
          home: Scaffold(
            body: AlarmWorkspace(
              catalog: ExternalCatalog(api, canDevelop: true),
              development: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('报警列配置'));
      await tester.pumpAndSettle();
      expectCleanUI(tester, '报警列配置');
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilterChip).first);
      await tester.enterText(find.byType(TextFormField).first, '自定义时间');
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expectCleanUI(tester, '报警列配置 · 键盘');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下移').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      final saved = api.screen['alarm_columns'] as List;
      expect(saved[1], {
        'key': 'event_time',
        'visible': true,
        'label': '自定义时间',
      });
      expect(find.text('自定义时间'), findsOneWidget);
      expect(find.text('2026-11-02 07:49:17'), findsOneWidget);
      expect(find.text('报警发生时间'), findsNothing);
      await tester.tap(find.text('查询条件'));
      await tester.pumpAndSettle();
      expectCleanUI(tester, '报警查询条件');
    });
  }
  test('reject invalid alarm layouts and preserve hidden column labels', () {
    final columns = alarmLayout({});
    columns.insert(0, columns.removeLast());
    columns.first.addAll({'label': '自定义标题', 'visible': false});
    expect(decodeAlarmLayout(encodeAlarmLayout(columns)), columns);
    for (final bad in [
      [],
      [...columns.skip(1), columns.last],
      [
        for (final c in columns) {...c, 'visible': false},
      ],
      [
        for (final c in columns) {...c, 'label': ' '},
      ],
    ]) {
      expect(() => validateLayout(bad), throwsFormatException);
    }
  });
}
