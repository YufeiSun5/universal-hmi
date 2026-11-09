import 'package:flutter/gestures.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/alarm_columns.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/reports.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'package:universal_hmi/shared/table.dart';
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
  testWidgets(
    'an open runtime applies a separate editor save to existing rows',
    (tester) async {
      final api = LayoutApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportQuery(api: api, screen: api.screen, autoQuery: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026-11-02 07:49:08'), findsOneWidget);
      final columns = alarmLayout(api.screen);
      for (final c in columns) {
        c['visible'] = c['key'] == 'event_time';
        if (c['visible'] == true) c['label'] = '现场时间';
      }
      await api.request(
        'POST',
        '/api/v1/external/screens',
        body: {...api.screen, 'alarm_columns': columns},
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('现场时间'), findsOneWidget);
      expect(find.text('2026-11-02 07:49:08'), findsNothing);
      expect(find.text('2026-11-02 07:49:17'), findsOneWidget);
      expect(api.bodies.length, 1);
    },
  );
  testWidgets(
    'overview reveals the station of a repeated row while hovering scrolled metrics',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewTable(
              rows: [
                for (final area in ['高区', '低区'])
                  {'id': area, 'name': '同一换热站', 'site': '中心所', 'area': area},
                {'id': 'next', 'site': '西所', 'name': '其他站', 'area': '单区'},
              ],
              columns: [
                for (var i = 0; i < 31; i++)
                  {'id': 'c$i', 'name': '列$i', 'group': '测点'},
              ],
              reading: (r, c) => const Text('25'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widgetList<Scrollable>(find.byType(Scrollable))
          .firstWhere((s) => s.axisDirection == AxisDirection.right);
      scroll.controller!.jumpTo(450);
      await tester.pump();
      final row = find.byKey(const ValueKey('低区'));
      final name = find.text('同一换热站');
      final top = tester.getTopLeft(find.byKey(const ValueKey('高区'))).dy;
      final bottom = tester.getBottomRight(row).dy;
      final midpoint = (top + bottom) / 2;
      for (final entry in [('中心所', '站所'), ('同一换热站', '换热站名称')]) {
        final center = tester.getCenter(find.text(entry.$1));
        expect(center.dy, closeTo(midpoint, 1));
        expect(center.dx, closeTo(tester.getCenter(find.text(entry.$2)).dx, 1));
      }
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      expect(name, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('低区')),
        findsOneWidget,
      );
      final highlight = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xffdaf0ff),
        ),
      );
      expect(highlight, findsOneWidget);
      expect(tester.getCenter(name).dy, closeTo(midpoint, 1));
      List<bool> highlights(String id) => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(ValueKey(id)),
              matching: find.byType(Container),
            ),
          )
          .where(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration as BoxDecoration).color != null,
          )
          .take(3)
          .map(
            (c) =>
                (c.decoration as BoxDecoration).color ==
                const Color(0xffc1e1f8),
          )
          .toList();
      expect(highlights('高区'), [true, true, false]);
      expect(highlights('低区'), [true, true, true]);
      expect(highlights('next'), [false, false, false]);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('next'))));
      await tester.pumpAndSettle();
      expect(highlights('低区'), [false, false, false]);
      expect(highlights('next'), [true, true, true]);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(name, findsOneWidget);
    },
  );
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
      await tester.ensureVisible(find.text('报表样式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('报表样式'));
      await tester.pumpAndSettle();
      expectCleanUI(tester, '报警结果列配置');
      await tester.enterText(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextFormField),
            )
            .first,
        '自定义时间',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expectCleanUI(tester, '报警结果列配置 · 键盘');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorder(0, 2);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存样式'));
      await tester.pumpAndSettle();
      final saved = api.screen['report_layouts']['alarm']['columns'] as List;
      expect(saved[1], {
        'key': 'event_time',
        'visible': true,
        'label': '自定义时间',
      });
      expect(find.text('自定义时间'), findsOneWidget);
      expect(find.text('2026-11-02 07:49:17'), findsOneWidget);
      expect(
        tester.widget<DenseTable>(find.byType(DenseTable).last).headers.take(2),
        ['报警发生时间', '自定义时间'],
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(TextField, '开始时间'), findsOneWidget);
      expect(find.byTooltip('选择开始时间'), findsOneWidget);
      expectCleanUI(tester, '报警页内查询条件');
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
