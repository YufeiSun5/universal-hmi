import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/role_management.dart';
import 'package:universal_hmi/features/security.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class RoleApi extends FakeApi {
  final role = <String, dynamic>{
    'id': 'duty',
    'name': '值班长',
    'version': 3,
    'members': 1,
    'grants': {
      'roles': ['operator'],
      'export': true,
    },
  };
  final direct = <String, dynamic>{
    'roles': ['viewer'],
    'station_ids': ['A'],
    'all_stations': false,
  };
  final mutations = <Json>[];
  bool reject = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (method != 'GET') {
      if (reject) throw Exception('角色版本已变化，请刷新');
      mutations.add({'method': method, 'path': path, 'body': body});
      return {};
    }
    if (path.endsWith('/roles')) {
      return {
        'items': [role],
      };
    }
    if (path.endsWith('/users')) {
      return {
        'items': [
          {
            'id': 'u1',
            'username': '张三',
            'version': 5,
            'custom_role_ids': ['duty'],
            'direct_grants': direct,
            'grants': {
              ...direct,
              'roles': ['viewer', 'operator'],
              'export': true,
            },
          },
          {
            'id': 'u2',
            'username': '李四',
            'version': 9,
            'custom_role_ids': [],
            'direct_grants': direct,
            'grants': direct,
          },
        ],
      };
    }
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'id': 'A', 'name': '一号站'},
        ],
      };
    }
    return {'items': []};
  }
}

Future<void> mount(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'role editor shows failed version save and preserves user input',
    (tester) async {
      final api = RoleApi()..reject = true;
      await mount(tester, RoleManager(api: api));
      await tester.tap(find.text('编辑角色'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '站长');
      await tester.tap(find.text('保存角色'));
      await tester.pumpAndSettle();
      expect(find.textContaining('角色版本已变化'), findsOneWidget);
      expect(find.text('站长'), findsOneWidget);
      expect(api.mutations, isEmpty);
      api.reject = false;
      await tester.tap(find.text('保存角色'));
      await tester.pumpAndSettle();
      final body = api.mutations.single['body'] as Json;
      expect(body['name'], '站长');
      expect(body['version'], 3);
      expect((body['grants'] as Json)['all_stations'], false);
    },
  );
  testWidgets(
    'member search selection submits only changed members with versions',
    (tester) async {
      final api = RoleApi();
      await mount(tester, RoleManager(api: api));
      await tester.tap(find.text('分配成员'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '李四');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选搜索结果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存成员'));
      await tester.pumpAndSettle();
      final body = api.mutations.single['body'] as Json;
      expect(body['version'], 3);
      expect(body['changes'], [
        {'user_id': 'u2', 'version': 9, 'assigned': true},
      ]);
    },
  );
  testWidgets(
    'user editor keeps inherited permissions separate from direct grants',
    (tester) async {
      final api = RoleApi();
      await mount(tester, SecurityPanel(api: api));
      await tester.tap(find.text('编辑权限').first);
      await tester.pumpAndSettle();
      final roleCheck = tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text('值班长'),
          matching: find.byType(CheckboxListTile),
        ),
      );
      expect(roleCheck.value, true);
      final operatorCheck = tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text('操作员'),
          matching: find.byType(CheckboxListTile),
        ),
      );
      expect(operatorCheck.value, false);
      await tester.tap(find.text('保存权限'));
      await tester.pumpAndSettle();
      final body = api.mutations.single['body'] as Json;
      expect(body['custom_role_ids'], ['duty']);
      expect((body['grants'] as Json)['roles'], ['viewer']);
      expect((body['grants'] as Json)['export'], false);
      expect((body['grants'] as Json)['station_ids'], ['A']);
    },
  );
}
