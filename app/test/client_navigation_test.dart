import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/monitor.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class ClientApi extends ScreenApi {
  bool withScreen = false, failQuery = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/external/screens') {
      requests.add('$method $path');
      return {
        'items': withScreen
            ? <Json>[
                {'id': 'daily', 'name': '日报', 'kind': 'hourly', 'revision': 1},
              ]
            : <Json>[],
      };
    }
    if (path == '/api/v1/external/sources') {
      requests.add('$method $path');
      return {'items': <Json>[]};
    }
    if (path == '/api/v1/external/screens/daily/stations') {
      requests.add('$method $path');
      return {
        'items': <Json>[
          {'code': 'A', 'name': 'A站'},
        ],
      };
    }
    if (path == '/api/v1/external/screens/daily/query') {
      requests.add('$method $path');
      if (failQuery) throw const PlatformRequestException(422, '外部查询失败');
      return {
        'points': <Json>[],
        'rows': <Json>[],
        'offset': 0,
        'has_more': false,
        'utc_offset_minutes': 480,
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  bool internal(String request) => [
    '/api/v1/history',
    '/api/v1/jobs',
    '/api/v1/storage',
    '/api/v1/events',
  ].any(request.contains);
  for (final initialView in ['runtime', 'history']) {
    testWidgets('工程师客户端 $initialView 只提供四项并使用外部历史', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = ClientApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Workspace(api: api, canDevelop: true, initialView: initialView),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['GIS', '工艺画面', '设备台账', '历史']) {
        expect(find.text(label), findsWidgets);
      }
      for (final label in ['数据总览', '历史报表', '历史数据', '变量监视', '外数据']) {
        expect(find.text(label), findsNothing);
      }
      if (initialView == 'runtime') {
        await tester.tap(find.text('历史').first);
        await tester.pumpAndSettle();
      }
      expect(find.text('暂无已授权的历史画面。'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新历史目录'));
      await tester.pumpAndSettle();
      expect(
        api.requests.any((r) => r.contains('/api/v1/external/screens')),
        isTrue,
      );
      expect(
        api.requests.where((r) => r.contains('/api/v1/external/sources')),
        isEmpty,
      );
      expect(
        api.requests.where(
          (r) =>
              r.contains('/api/v1/history') ||
              r.contains('/api/v1/jobs') ||
              r.contains('/api/v1/storage'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('工艺切站保持客户端并不请求内部工具', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ClientApi();
    api.rows.addAll([api.point('a', 'A'), api.point('b', 'B')]);
    for (final s in ['A', 'B']) {
      api.screens[s] = ScreenDocument(
        id: s,
        name: '$s 工艺',
        station: s,
        revision: 1,
        nodes: [],
      ).toJson();
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(api: api, canDevelop: true, initialView: 'process'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('navigation-open-scope-B')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final monitor = tester.widget<HeatingMonitor>(find.byType(HeatingMonitor));
    expect(monitor.activePage, 9);
    expect(monitor.station, 'B');
    expect(api.requests.where(internal), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('外部历史查询成功和失败都不回退内部历史', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ClientApi()..withScreen = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(api: api, canDevelop: true, initialView: 'history'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('日报'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('编辑画面名称'), findsNothing);
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    api.failQuery = true;
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(find.textContaining('外部查询失败'), findsOneWidget);
    expect(
      api.requests
          .where((r) => r.contains('/external/screens/daily/query'))
          .length,
      2,
    );
    expect(api.requests.where(internal), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('窄屏四项均可访问', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ClientApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(api: api, canDevelop: true, initialView: 'runtime'),
      ),
    );
    await tester.pumpAndSettle();
    for (final entry in {'工艺画面': 9, '设备台账': 13, '历史': 12, 'GIS': 11}.entries) {
      await tester.ensureVisible(find.text(entry.key).first);
      await tester.tap(find.text(entry.key).first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<HeatingMonitor>(find.byType(HeatingMonitor)).activePage,
        entry.value,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('未指定视图的工程师仍进入开发工作台', (tester) async {
    final api = ClientApi();
    await tester.pumpWidget(
      MaterialApp(home: Workspace(api: api, canDevelop: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HeatingMonitor), findsNothing);
    expect(
      api.requests.any((r) => r.contains('/api/v1/history/catalog')),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
