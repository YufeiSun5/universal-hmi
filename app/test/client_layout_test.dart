import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/process/monitor_chrome.dart';
import 'package:universal_hmi/features/security.dart';
import 'client_navigation_test.dart' show ClientApi;
import 'workspace_test.dart' show FakeApi;

void main() {
  testWidgets('历史目录与主栏齐边，窄窗抽屉选择后关闭且保留查询', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ClientApi()..withScreen = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(api: api, canDevelop: false, initialView: 'history'),
      ),
    );
    await tester.pumpAndSettle();
    final directory = find.byType(ExternalDataPanel);
    expect(tester.getTopLeft(directory).dx, 0);
    expect(
      tester.getTopLeft(directory).dy,
      tester.getBottomLeft(find.byType(MonitorHeader)).dy,
    );
    await tester.tap(find.text('日报'));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(640, 480));
    await tester.pumpAndSettle();
    expect(directory, findsNothing);
    expect(find.text('查询'), findsOneWidget);
    expect(tester.getTopLeft(find.text('查询')).dx, lessThan(640));
    await tester.tap(find.byTooltip('显示或收起目录'));
    await tester.pumpAndSettle();
    expect(directory, findsOneWidget);
    await tester.tap(find.descendant(of: directory, matching: find.text('日报')));
    await tester.pumpAndSettle();
    expect(directory, findsNothing);
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(
      api.requests.where((r) => r.contains('/external/screens/daily/query')),
      hasLength(1),
    );
    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pumpAndSettle();
    expect(directory, findsOneWidget);
    expect(find.text('查询'), findsOneWidget);
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
          home: Scaffold(body: SecurityPanel(api: FakeApi())),
        ),
      );
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
