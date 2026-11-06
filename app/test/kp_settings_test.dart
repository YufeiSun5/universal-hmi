import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/kp_settings.dart';
import 'package:universal_hmi/features/security_navigation.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class KPSettingsApi extends FakeApi {
  final saves = <Json>[], actions = <Json>[];
  bool conflict = false;
  Json current = {
    'revision': 'absent',
    'enabled': false,
    'kp_server': '',
    'kp_project': '',
    'kp_origins': <String>[],
    'users': <Json>[],
    'public_origin': 'https://hmi.example:9090',
    'running': false,
    'public_listening': true,
    'pending': false,
  };
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/users')) {
      return {
        'items': [
          {'id': 'internal-1', 'username': '巡检账号', 'disabled': false},
          {'id': 'disabled-1', 'username': '停用账号', 'disabled': true},
        ],
      };
    }
    if (method == 'PUT') {
      final input = Map<String, dynamic>.from(body! as Map);
      saves.add(input);
      if (conflict) throw const PlatformRequestException(409, '配置已改变');
      current = {
        ...current,
        ...input,
        'revision': 'saved-revision',
        'pending': true,
      };
    }
    if (method == 'POST') {
      final input = Map<String, dynamic>.from(body! as Map);
      actions.add(input);
      if (input['action'] == 'check') return {'message': '核验接口可达；真实账号登录仍需验证'};
      current = {...current, 'running': current['enabled'], 'pending': false};
    }
    return Map<String, dynamic>.from(current);
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> top(WidgetTester tester) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'KP setup separates public and backend addresses, maps searched account and applies saved config',
    (tester) async {
      final api = KPSettingsApi();
      await tester.pumpWidget(MaterialApp(home: KPSettingsPage(api: api)));
      await tester.pumpAndSettle();
      expect(find.textContaining('127.0.0.1'), findsNothing);
      await tapVisible(tester, find.byType(SwitchListTile));
      await tester.enterText(
        find.widgetWithText(TextField, 'KP 公网网页地址'),
        'https://kp.example\nhttps://kp2.example:10443',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'KP 后台服务地址'),
        'http://127.0.0.1:11005',
      );
      await tapVisible(tester, find.text('添加'));
      await tester.enterText(find.widgetWithText(TextField, 'KP 稳定用户 ID'), '2');
      await tester.enterText(find.widgetWithText(TextField, '搜索并选择监控账号'), '巡检');
      await tester.pumpAndSettle();
      await tester.tap(find.text('巡检账号').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('巡检账号'), findsOneWidget);
      await tapVisible(tester, find.text('保存配置'));
      expect(api.saves.single['kp_origins'], [
        'https://kp.example',
        'https://kp2.example:10443',
      ]);
      expect(
        (api.saves.single['users'] as List).single['user_id'],
        'internal-1',
      );
      await top(tester);
      expect(find.text('实际状态：KP 接入未运行'), findsOneWidget);
      expect(api.actions, isEmpty);
      await tapVisible(tester, find.text('应用配置'));
      expect(api.actions, isEmpty);
      await tester.tap(find.text('应用配置').last);
      await tester.pumpAndSettle();
      expect(api.actions.single, {
        'revision': 'saved-revision',
        'action': 'apply',
      });
      await top(tester);
      expect(find.text('实际状态：KP 接入已启用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed save preserves draft and dirty configuration cannot be applied',
    (tester) async {
      final api = KPSettingsApi()..conflict = true;
      await tester.pumpWidget(MaterialApp(home: KPSettingsPage(api: api)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'KP 公网网页地址'),
        'https://draft.example',
      );
      await tapVisible(tester, find.text('保存配置'));
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '应用配置'))
            .onPressed,
        isNull,
      );
      await top(tester);
      expect(find.text('https://draft.example'), findsOneWidget);
      expect(find.text('配置已改变'), findsOneWidget);
      expect(api.actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow page generates escaped script only for valid container and HTTPS origin',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: KPSettingsPage(api: KPSettingsApi())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, '网页容器名称'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('var hmiBase = "https://hmi.example:9090";'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, '网页容器名称'),
        'x;alert(1)',
      );
      await tester.pumpAndSettle();
      expect(find.text('复制画面打开时脚本'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, '网页容器名称'),
        'WebContainer9',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('HMIKP.open(hmiBase, WebContainer9'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('KP management entry only appears with management callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecurityNavigation(username: 'viewer', onRecords: () {}),
        ),
      ),
    );
    expect(find.text('KP 接入'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecurityNavigation(
            username: 'admin',
            onRecords: () {},
            onUsers: () {},
            onKP: () {},
          ),
        ),
      ),
    );
    expect(find.text('KP 接入'), findsOneWidget);
  });
}
