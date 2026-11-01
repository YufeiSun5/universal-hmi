import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/process/monitor_chrome.dart';
import 'package:universal_hmi/features/security.dart';
import 'client_navigation_test.dart' show ClientApi;
import 'workspace_test.dart' show FakeApi;
import 'package:universal_hmi/shared/api.dart';

class LayoutClientApi extends ClientApi {
  Json? lastQuery;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (path.endsWith('/daily/stations')) {
      return Future.value({
        'items': <Json>[
          {'code': 'A', 'name': 'A站'},
          {'code': 'B', 'name': 'B站'},
        ],
      });
    }
    if (path.endsWith('/daily/query')) lastQuery = body as Json;
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets('历史目录与主栏齐边，窄窗抽屉选择后关闭且保留查询', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = LayoutClientApi()..withScreen = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(api: api, canDevelop: false, initialView: 'history'),
      ),
    );
    await tester.pumpAndSettle();
    final directory = find.byType(ExternalDataPanel);
    final dailyEntry = find.descendant(
      of: directory,
      matching: find.byWidgetPredicate((w) => w is Text && w.data == '日报'),
    );
    expect(tester.getTopLeft(directory).dx, 0);
    expect(
      tester.getTopLeft(directory).dy,
      tester.getBottomLeft(find.byType(MonitorHeader)).dy,
    );
    await tester.enterText(
      find.descendant(of: directory, matching: find.byType(TextField)),
      '日报',
    );
    await tester.pumpAndSettle();
    await tester.tap(dailyEntry);
    await tester.pumpAndSettle();
    final dateField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '日期 YYYY-MM-DD',
    );
    await tester.tap(find.text('A站'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B站').last);
    await tester.pumpAndSettle();
    await tester.enterText(dateField, '2026-10-20');
    await tester.binding.setSurfaceSize(const Size(640, 480));
    await tester.pumpAndSettle();
    expect(directory, findsNothing);
    expect(find.text('查询'), findsOneWidget);
    expect(tester.getTopLeft(find.text('查询')).dx, lessThan(640));
    await tester.tap(find.byTooltip('显示或收起目录'));
    await tester.pumpAndSettle();
    expect(directory, findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.descendant(of: directory, matching: find.byType(TextField)),
          )
          .controller!
          .text,
      '日报',
    );
    final drawerSearch = find.descendant(
      of: directory,
      matching: find.byType(TextField),
    );
    await tester.enterText(drawerSearch, '不存在的画面');
    await tester.pumpAndSettle();
    expect(dailyEntry, findsNothing);
    expect(find.text('没有匹配的画面'), findsOneWidget);
    await tester.enterText(drawerSearch, '日报');
    await tester.pumpAndSettle();
    expect(dailyEntry, findsOneWidget);
    await tester.tap(dailyEntry);
    await tester.pumpAndSettle();
    expect(directory, findsNothing);
    expect(tester.widget<TextField>(dateField).controller!.text, '2026-10-20');
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(
      api.requests.where((r) => r.contains('/external/screens/daily/query')),
      hasLength(1),
    );
    expect(api.lastQuery?['date'], '2026-10-20');
    expect(api.lastQuery?['station'], 'B');
    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pumpAndSettle();
    expect(directory, findsOneWidget);
    expect(find.text('查询'), findsOneWidget);
    expect(tester.widget<TextField>(dateField).controller!.text, '2026-10-20');
    expect(
      tester
          .widget<TextField>(
            find.descendant(of: directory, matching: find.byType(TextField)),
          )
          .controller!
          .text,
      '日报',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(900, 600),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets('权限工具栏 ${size.width} 窗口动作可见且不溢出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SecurityPanel(api: FakeApi()),
                ),
                child: const Text('打开权限'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开权限'));
      await tester.pumpAndSettle();
      for (final text in ['账号与范围', '登录会话', '角色管理', '新建账号']) {
        expect(find.text(text).hitTestable(), findsOneWidget);
      }
      expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('登录会话'));
      await tester.pumpAndSettle();
      expect(find.text('新建账号'), findsNothing);
      await tester.tap(find.text('账号与范围'));
      await tester.pumpAndSettle();
      expect(find.text('新建账号').hitTestable(), findsOneWidget);
      if (size.width == 900) {
        await tester.tap(find.text('新建账号'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(find.byType(SecurityPanel), findsOneWidget);
        expect(find.text('新建账号').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
