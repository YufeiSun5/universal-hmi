import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/public_access_events.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'workspace_test.dart' show FakeApi;

Json auditRow(int seq) => {
  'seq': seq,
  'at': '2026-10-31T16:00:00Z',
  'ip': '2001:db8:1234:5678:abcd:9876:1234:ffff',
  'channel': 'public:web',
  'user_id': '',
  'kind': 'api_request',
  'route': '/api/v1/screens/{id}',
  'method': 'GET',
  'status': 403,
  'decision': 'public_ip_denied',
  'rule_id': 'rule-1',
  'owner_label': '人工标注的办公网络，不能推断请求账号',
  'owner_user_id': 'label-owner',
};
Json auditPage(List<Json> items, {int next = 0}) => {
  'items': items,
  'next_before': next,
  'status': {
    'enabled': true,
    'queue_depth': 2,
    'dropped': 3,
    'write_failures': 4,
    'last_write_at': '2026-10-31T16:00:00Z',
    'last_error': 'write failure secret not for UI',
    'retention_days': 14,
    'max_events': 100000,
  },
};

class EventsApi extends FakeApi {
  final queries = <Json>[];
  Json page = auditPage([auditRow(10)]);
  Completer<Json>? pending;
  bool failRequest = false, pages = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/security/public-access/events');
    expect(query?['limit'], 100);
    queries.add({...?query});
    if (failRequest) throw const PlatformRequestException(503, 'unavailable');
    if (pending != null) return pending!.future;
    if (pages) {
      final start = query?['before'] as int? ?? 1000;
      return auditPage(
        List.generate(100, (i) => auditRow(start - i)),
        next: start - 100,
      );
    }
    return page;
  }
}

Future<void> openEvents(
  WidgetTester tester,
  EventsApi api, {
  Size size = const Size(1100, 800),
  bool settle = true,
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
              builder: (_) => PublicAccessEventsPanel(api: api),
            ),
            child: const Text('打开记录'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开记录'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets(
    'bounded record meaning and server health remain visible without identity inference',
    (tester) async {
      final api = EventsApi();
      await openEvents(tester, api);
      expect(find.text('公网请求记录，不等于页面浏览证明，正常资源请求不记录。'), findsOneWidget);
      expect(find.textContaining('排队 2 · 已丢弃 3 · 写入失败 4'), findsOneWidget);
      expect(find.textContaining('记录服务报告写入异常'), findsOneWidget);
      expect(find.textContaining('secret not for UI'), findsNothing);
      expect(find.textContaining('当时人工关联账号 ID：label-owner'), findsOneWidget);
      expect(find.text('已认证账号 ID：未认证或未解析'), findsOneWidget);
      expect(find.textContaining('请求记录，不等于'), findsOneWidget);
      expect(find.text('清空'), findsNothing);
    },
  );
  testWidgets(
    'unknown decisions are generic and authenticated ID is independent of owner',
    (tester) async {
      final api = EventsApi()
        ..page = auditPage([
          {
            ...auditRow(10),
            'decision': '<unexpected secret>',
            'user_id': 'authenticated-user',
            'owner_user_id': 'different-owner',
          },
        ]);
      await openEvents(tester, api);
      expect(find.textContaining('未识别结果'), findsOneWidget);
      expect(find.textContaining('<unexpected secret>'), findsNothing);
      expect(find.text('已认证账号 ID：authenticated-user'), findsOneWidget);
      expect(
        find.textContaining('当时人工关联账号 ID：different-owner'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'pagination appends cursor results and refresh resets latest view',
    (tester) async {
      final api = EventsApi()..page = auditPage([auditRow(10)], next: 10);
      await openEvents(tester, api);
      api.page = auditPage([auditRow(9)]);
      await tester.ensureVisible(find.text('加载更早'));
      await tester.tap(find.text('加载更早'));
      await tester.pumpAndSettle();
      expect(api.queries.last['before'], 10);
      expect(find.text('当前显示 2 条'), findsOneWidget);
      api.page = auditPage([auditRow(20)]);
      await tester.ensureVisible(find.text('刷新记录'));
      await tester.tap(find.text('刷新记录'));
      await tester.pumpAndSettle();
      expect(api.queries.last.containsKey('before'), false);
      expect(find.text('当前显示 1 条'), findsOneWidget);
    },
  );
  testWidgets(
    'pending callbacks cannot duplicate load and closing ignores late response',
    (tester) async {
      final api = EventsApi();
      await openEvents(tester, api);
      api.pending = Completer<Json>();
      final refresh = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '刷新记录'))
          .onPressed!;
      refresh();
      refresh();
      await tester.pump();
      expect(api.queries, hasLength(2));
      await tester.tap(find.byTooltip('关闭请求记录'));
      await tester.pumpAndSettle();
      api.pending!.complete(auditPage([auditRow(99)]));
      await tester.pumpAndSettle();
      expect(find.byType(PublicAccessEventsPanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed refresh keeps old data with incomplete warning and unavailable status',
    (tester) async {
      final api = EventsApi()..page = auditPage([auditRow(10)]);
      api.page['status']['enabled'] = false;
      await openEvents(tester, api);
      api.failRequest = true;
      await tester.tap(find.text('刷新记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已有记录仅为先前结果'), findsOneWidget);
      expect(find.text('当前显示 1 条'), findsOneWidget);
      expect(find.text('本地记录器未就绪或不可用'), findsOneWidget);
      expect(find.text('以下服务状态来自上次成功响应，当前状态尚未确认。'), findsOneWidget);
      expect(find.textContaining('当前查询范围已无更早记录'), findsNothing);
    },
  );
  testWidgets('first load failure is not an empty or complete record set', (
    tester,
  ) async {
    final api = EventsApi()..failRequest = true;
    await openEvents(tester, api);
    expect(find.text('记录服务状态尚未确认'), findsOneWidget);
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.textContaining('当前查询没有记录'), findsNothing);
  });
  testWidgets('long IP and labels wrap in narrow actual theme', (tester) async {
    final api = EventsApi();
    await openEvents(tester, api, size: const Size(460, 640));
    await tester.ensureVisible(find.text('已认证账号 ID：未认证或未解析'));
    await tester.pump();
    expect(find.textContaining('2001:db8:1234:5678'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'pagination is capped at 500 rows without claiming earlier history absent',
    (tester) async {
      final api = EventsApi()..pages = true;
      await openEvents(tester, api);
      for (var i = 0; i < 4; i++) {
        await tester.scrollUntilVisible(
          find.text('加载更早'),
          1500,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 250,
        );
        await tester.tap(find.text('加载更早'));
        await tester.pumpAndSettle();
      }
      expect(api.queries, hasLength(5));
      expect(find.text('加载更早'), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('已达本页 500 条上限'),
        1500,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 250,
      );
      expect(find.textContaining('更早记录未展示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
