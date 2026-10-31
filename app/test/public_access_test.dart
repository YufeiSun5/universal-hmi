import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/public_access.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'workspace_test.dart' show FakeApi;

class PublicPolicyApi extends FakeApi {
  Json snapshot = {
    'schema': 1,
    'revision': 4,
    'source': 'database',
    'rules': <Json>[],
  };
  final policyWrites = <Json>[];
  bool conflict = false, failLoad = false;
  Completer<Json>? pendingGet, pendingSave;
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
          {'id': 'u1', 'username': '测试用户', 'disabled': false},
        ],
      };
    }
    if (path != '/api/v1/security/public-access') throw StateError(path);
    if (method == 'GET') {
      if (pendingGet != null) return pendingGet!.future;
      if (failLoad) {
        throw const PlatformRequestException(503, 'policy_unavailable');
      }
      return snapshot;
    }
    final data = Map<String, dynamic>.from(body! as Map);
    policyWrites.add(data);
    if (conflict) throw const PlatformRequestException(409, 'policy_conflict');
    if (pendingSave != null) return pendingSave!.future;
    snapshot = {...data, 'schema': 1, 'source': 'database', 'revision': 5};
    return snapshot;
  }
}

Json rule() => {
  'id': 'r1',
  'cidr': '192.0.2.0/24',
  'owner_label': '合成办公室',
  'owner_user_id': 'missing-user',
  'owner_status': 'missing',
  'remark': '人工备注',
  'enabled': true,
};
Future<void> openPolicy(
  WidgetTester tester,
  PublicPolicyApi api, {
  Size size = const Size(1100, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(false),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => PublicAccessPanel(api: api),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> addRule(WidgetTester tester) async {
  await tester.tap(find.text('添加规则'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('public-rule-IP/CIDR')),
    '198.51.100.1',
  );
  await tester.enterText(find.byKey(const Key('public-rule-归属标签')), '手工登记');
  await tester.enterText(
    find.byKey(const Key('public-rule-到期时间 RFC3339（可选）')),
    '2099-01-01T08:00:00+08:00',
  );
  await tester.tap(find.text('应用到草稿'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'file save requires confirmation and submits revision plus writable fields',
    (tester) async {
      final api = PublicPolicyApi()
        ..snapshot = {
          'schema': 1,
          'revision': 0,
          'source': 'file',
          'rules': [rule()],
        };
      await openPolicy(tester, api);
      await addRule(tester);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      expect(find.text('切换为数据库策略'), findsOneWidget);
      expect(api.policyWrites, isEmpty);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('未保存修改'), findsOneWidget);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(api.policyWrites.single['revision'], 0);
      final rules = api.policyWrites.single['rules'] as List;
      expect((rules.first as Map).containsKey('owner_status'), false);
      expect(rules.first['owner_user_id'], 'missing-user');
      expect(rules.last['id'], '');
      expect(rules.last['expires_at'], '2099-01-01T00:00:00.000Z');
      expect(find.text('未保存修改'), findsNothing);
    },
  );
  testWidgets(
    'conflict retains draft and refresh or close cannot discard silently',
    (tester) async {
      final api = PublicPolicyApi()..conflict = true;
      await openPolicy(tester, api);
      await addRule(tester);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      expect(find.textContaining('草稿已保留'), findsOneWidget);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.textContaining('198.51.100.1'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭白名单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(PublicAccessPanel), findsOneWidget);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.text('未保存修改'), findsNothing);
    },
  );
  testWidgets(
    'pending save blocks duplicate submission and Back until completed',
    (tester) async {
      final api = PublicPolicyApi()..pendingSave = Completer<Json>();
      await openPolicy(tester, api);
      await addRule(tester);
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存策略'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(api.policyWrites, hasLength(1));
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pump();
      expect(find.byType(PublicAccessPanel), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '关闭白名单',
              ),
            )
            .onPressed,
        isNull,
      );
      api.pendingSave!.complete({
        ...api.snapshot,
        'revision': 5,
        'rules': api.policyWrites.single['rules'],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭白名单'));
      await tester.pumpAndSettle();
      expect(find.byType(PublicAccessPanel), findsNothing);
    },
  );
  testWidgets('pending refresh locks existing rule edits and deletion', (
    tester,
  ) async {
    final api = PublicPolicyApi()
      ..snapshot = {
        'schema': 1,
        'revision': 4,
        'source': 'database',
        'rules': [rule()],
      };
    await openPolicy(tester, api);
    api.pendingGet = Completer<Json>();
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '编辑规则'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '删除规则'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '添加规则'))
          .onPressed,
      isNull,
    );
    api.pendingGet!.complete(api.snapshot);
    await tester.pumpAndSettle();
    expect(find.text('未保存修改'), findsNothing);
  });
  testWidgets(
    'cancel editor preserves original draft and missing owner remains explicit',
    (tester) async {
      final api = PublicPolicyApi()
        ..snapshot = {
          'schema': 1,
          'revision': 4,
          'source': 'database',
          'rules': [rule()],
        };
      await openPolicy(tester, api);
      expect(find.textContaining('账号已不存在'), findsOneWidget);
      await tester.tap(find.text('编辑规则'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('public-rule-归属标签')), '不应保存');
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(find.text('放弃规则编辑？'), findsOneWidget);
      await tester.tap(find.text('放弃编辑'));
      await tester.pumpAndSettle();
      expect(find.textContaining('合成办公室'), findsOneWidget);
      expect(find.textContaining('不应保存'), findsNothing);
      expect(find.text('未保存修改'), findsNothing);
    },
  );
  testWidgets(
    'narrow window deletion is draft only and empty list can be saved',
    (tester) async {
      final api = PublicPolicyApi()
        ..snapshot = {
          'schema': 1,
          'revision': 4,
          'source': 'database',
          'rules': [rule()],
        };
      await openPolicy(tester, api, size: const Size(460, 640));
      await tester.tap(find.text('删除规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除规则'));
      await tester.pumpAndSettle();
      expect(api.policyWrites, isEmpty);
      expect(find.text('没有白名单规则。'), findsOneWidget);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      expect(api.policyWrites.single['rules'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('load error is visible and does not fabricate editable policy', (
    tester,
  ) async {
    final api = PublicPolicyApi()..failLoad = true;
    await openPolicy(tester, api);
    expect(find.textContaining('policy_unavailable'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '添加规则'))
          .onPressed,
      isNull,
    );
    api.failLoad = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '添加规则'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'narrow editor validates expiry and permits unlabelled disabled rule',
    (tester) async {
      final api = PublicPolicyApi()
        ..snapshot = {
          'schema': 1,
          'revision': 4,
          'source': 'database',
          'rules': [rule()],
        };
      await openPolicy(tester, api, size: const Size(460, 640));
      await tester.tap(find.text('编辑规则'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('public-rule-归属标签')), '');
      await tester.enterText(
        find.byKey(const Key('public-rule-到期时间 RFC3339（可选）')),
        'not-a-date',
      );
      await tester.tap(find.text('应用到草稿'));
      await tester.pumpAndSettle();
      expect(find.textContaining('到期时间须为'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('public-rule-到期时间 RFC3339（可选）')),
        '',
      );
      await tester.ensureVisible(find.text('启用规则'));
      await tester.tap(find.text('启用规则'));
      await tester.pump();
      await tester.tap(find.text('应用到草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      final saved = (api.policyWrites.single['rules'] as List).single as Map;
      expect(saved['id'], 'r1');
      expect(saved['owner_label'], '');
      expect(saved['enabled'], false);
      expect(saved.containsKey('expires_at'), false);
      expect(saved.containsKey('owner_status'), false);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'repeated apply callback closes only editor and adds one draft rule',
    (tester) async {
      final api = PublicPolicyApi();
      await openPolicy(tester, api);
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('public-rule-IP/CIDR')),
        '192.0.2.12',
      );
      final apply = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用到草稿'))
          .onPressed!;
      apply();
      apply();
      await tester.pumpAndSettle();
      expect(find.text('白名单规则'), findsNothing);
      expect(find.byType(PublicAccessPanel), findsOneWidget);
      expect(find.textContaining('192.0.2.12'), findsOneWidget);
      expect(find.text('未保存修改'), findsOneWidget);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      expect(api.policyWrites, hasLength(1));
      expect(api.policyWrites.single['rules'], hasLength(1));
    },
  );

  testWidgets(
    'repeated clean close exits policy once and preserves host route',
    (tester) async {
      final api = PublicPolicyApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(false),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (hostContext) => Scaffold(
                      body: TextButton(
                        onPressed: () => showDialog<void>(
                          context: hostContext,
                          builder: (_) => PublicAccessPanel(api: api),
                        ),
                        child: const Text('打开策略'),
                      ),
                    ),
                  ),
                ),
                child: const Text('进入管理页'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('进入管理页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开策略'));
      await tester.pumpAndSettle();
      final close = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '关闭白名单',
            ),
          )
          .onPressed!;
      close();
      close();
      await tester.pumpAndSettle();
      expect(find.byType(PublicAccessPanel), findsNothing);
      expect(find.text('打开策略'), findsOneWidget);
      expect(find.text('进入管理页'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
