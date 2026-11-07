import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/kp_settings.dart';
import 'package:universal_hmi/features/security_navigation.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class KPSettingsApi extends FakeApi {
  final saves = <Json>[], actions = <Json>[];
  bool conflict = false, applyFailure = false;
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
    'ready': true,
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
        'ready':
            input['enabled'] != true ||
            (input['mode'] == 'trial'
                ? '${input['trial_user_id'] ?? ''}'.isNotEmpty
                : '${input['kp_server']}'.isNotEmpty),
        'validation_error':
            input['enabled'] == true && '${input['kp_server']}'.isEmpty
            ? '待完善：请补充服务器可访问的 KP 后台服务地址；普通登录仍可用'
            : '',
      };
    }
    if (method == 'POST') {
      final input = Map<String, dynamic>.from(body! as Map);
      actions.add(input);
      if (input['action'] == 'check') return {'message': '核验接口可达；真实账号登录仍需验证'};
      if (applyFailure) {
        current['status_error'] = '应用失败：公网入口未就绪';
        throw const PlatformRequestException(422, '应用失败：公网入口未就绪');
      }
      current = {
        ...current,
        'running': current['enabled'],
        'pending': false,
        'active_server': current['kp_server'],
        'active_origins': current['kp_origins'],
        'active_revision': current['revision'],
        'active_mode': current['mode'] ?? 'verified',
        'trial_key': current['mode'] == 'trial' ? 'T' * 43 : '',
        'trial_user_name': current['mode'] == 'trial' ? '巡检账号' : '',
        'status_error': '',
      };
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
    'trial mode applies with empty KP server and generates fixed-account capability script',
    (tester) async {
      final api = KPSettingsApi();
      await tester.pumpWidget(MaterialApp(home: KPSettingsPage(api: api)));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byType(SwitchListTile));
      await tapVisible(tester, find.text('联调模式'));
      await tapVisible(tester, find.widgetWithText(TextField, '搜索并选择固定测试账号'));
      await tester.enterText(
        find.widgetWithText(TextField, '搜索并选择固定测试账号'),
        '巡检',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('巡检账号').last);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.widgetWithText(TextField, 'KP 公网网页地址'));
      await tester.enterText(
        find.widgetWithText(TextField, 'KP 公网网页地址'),
        'http://127.0.0.1:11005',
      );
      await tapVisible(tester, find.text('保存配置'));
      expect(api.saves.single['kp_server'], '');
      expect(api.saves.single['mode'], 'trial');
      expect(api.saves.single['trial_user_id'], 'internal-1');
      await tapVisible(tester, find.text('应用配置'));
      await tester.tap(find.text('应用配置').last);
      await tester.pumpAndSettle();
      await top(tester);
      expect(find.text('实际状态：联调模式／未核验 KP 身份'), findsOneWidget);
      expect(find.text('固定测试账号：巡检账号（只读）'), findsOneWidget);
      await tapVisible(tester, find.text('复制画面打开时脚本'));
      expect(
        find.textContaining('HMIKP.openTrial(hmiBase, WebContainer1'),
        findsOneWidget,
      );
      expect(find.textContaining('GetCurrentUser()'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty backend address saves a draft and completing it enables apply',
    (tester) async {
      final api = KPSettingsApi();
      api.current = {
        ...api.current,
        'enabled': true,
        'kp_origins': ['https://kp.example'],
        'users': [
          {'subject': '2', 'user_id': 'internal-1'},
        ],
        'ready': false,
        'validation_error': '待完善：请补充服务器可访问的 KP 后台服务地址；普通登录仍可用',
      };
      await tester.pumpWidget(MaterialApp(home: KPSettingsPage(api: api)));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('保存配置'));
      expect(api.saves.single['kp_server'], '');
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '应用配置'))
            .onPressed,
        isNull,
      );
      await top(tester);
      expect(find.text('已保存草稿，待完善'), findsOneWidget);
      expect(find.text('KP 自动接入待配置，普通登录仍可用。'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(TextField, 'KP 后台服务地址'));
      await tester.enterText(
        find.widgetWithText(TextField, 'KP 后台服务地址'),
        'http://172.16.1.8:11005',
      );
      await tapVisible(tester, find.text('保存配置'));
      await tapVisible(tester, find.text('应用配置'));
      await tester.tap(find.text('应用配置').last);
      await tester.pumpAndSettle();
      await top(tester);
      expect(find.text('实际状态：KP 接入已启用'), findsOneWidget);
      expect(find.text('实际核验地址：http://172.16.1.8:11005'), findsOneWidget);
      expect(find.text('已保存配置与应用状态一致'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed apply refreshes active status and retains saved replacement',
    (tester) async {
      final api = KPSettingsApi()..applyFailure = true;
      api.current = {
        ...api.current,
        'enabled': true,
        'kp_server': 'https://new.example',
        'running': true,
        'pending': true,
        'active_server': 'https://old.example',
        'active_origins': ['https://old-page.example'],
        'active_revision': 'old-revision',
      };
      await tester.pumpWidget(MaterialApp(home: KPSettingsPage(api: api)));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('应用配置'));
      await tester.tap(find.text('应用配置').last);
      await tester.pumpAndSettle();
      await top(tester);
      expect(find.text('仍在使用已生效配置，本页修改尚未替换它。'), findsOneWidget);
      expect(find.text('实际核验地址：https://old.example'), findsOneWidget);
      expect(find.text('已保存配置待应用'), findsOneWidget);
      expect(find.text('https://new.example'), findsOneWidget);
      expect(find.textContaining('应用失败：公网入口未就绪'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
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
