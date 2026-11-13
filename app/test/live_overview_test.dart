import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/features/process/monitor_chrome.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class OverviewApi extends FakeApi {
  Json config = {
    'revision': 1,
    'columns': <Json>[
      {'id': 'temp', 'group': '一次网', 'name': '供水温度', 'decimals': 1},
      {'id': 'pressure', 'group': '一次网', 'name': '供水压力', 'decimals': 2},
    ],
    'rows': <Json>[
      {
        'id': 'a',
        'area': '一区',
        'name': '第一站',
        'station': 'A',
        'bindings': {'temp': 'a', 'pressure': 'b'},
      },
      {
        'id': 'b',
        'area': '二区',
        'name': '第二站',
        'station': 'B',
        'bindings': {'temp': 'c'},
      },
    ],
  };
  bool conflict = false;
  int saveCount = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == overviewPath) {
      if (method == 'PUT') {
        saveCount++;
        if (conflict) throw const PlatformRequestException(409, '总览版本冲突，草稿保留');
        config = jsonDecode(jsonEncode(body)) as Json;
        config['revision'] = (config['revision'] as int) + 1;
      }
      return jsonDecode(jsonEncode(config)) as Json;
    }
    return super.request(method, path, body: body, query: query);
  }
}

const definitions = <String, Json>{
  'a': {'id': 'a', 'name': '供温', 'station': 'A', 'unit': '℃'},
  'b': {'id': 'b', 'name': '供压', 'station': 'A', 'unit': 'MPa'},
  'c': {'id': 'c', 'name': '供温', 'station': 'B', 'unit': '℃'},
};
const live = <String, Json>{
  'a': {'value': 62.56, 'quality': 'good'},
  'b': {'value': 123, 'quality': 'bad'},
  'c': {'value': 70, 'quality': 'good'},
};
void main() {
  test(
    'updated reference report has separate makeup pumps and three filters',
    () {
      final reference = jsonDecode(
        File(
          'test/fixtures/overview_reference_columns_v72.json',
        ).readAsStringSync(),
      );
      expect(overviewReferenceColumns, reference);
      expect(overviewReferenceColumns.length, 33);
      final rows = <Json>[
        {'site': '一所', 'name': '中心站', 'area': '高区', 'station': 'A'},
        {'site': '一所', 'name': '中心站', 'area': '低区', 'station': 'B'},
        {'site': '二所', 'name': '中心站', 'area': '高区', 'station': 'C'},
      ];
      expect(
        filterOverviewRows(rows, {
          'site': {'一所'},
          'name': {'中心站'},
          'area': {'高区'},
        }, ''),
        [rows[0]],
      );
      expect(filterOverviewRows(rows, {'area': <String>{}}, ''), isEmpty);
      expect(filterOverviewRows(rows, {}, ''), rows);
    },
  );
  testWidgets('mobile station view, quality, complete table and no writes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = OverviewApi();
    Set<String> selection = {};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveOverview(
            api: api,
            androidClient: true,
            definitions: definitions,
            live: live,
            online: true,
            onSubscriptionChanged: (ids) => selection = ids,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('62.6 ℃'), findsOneWidget);
    expect(find.text('-'), findsOneWidget);
    expect(find.text('123.00 MPa'), findsNothing);
    expect(selection, {'a', 'b'});
    expect(find.text('配置总览'), findsNothing);
    await tester.tap(find.byTooltip('切换完整表格'));
    await tester.pumpAndSettle();
    expect(find.byType(OverviewTable), findsOneWidget);
    expect(selection, {'a', 'b', 'c'});
    await tester.dragFrom(
      tester.getTopLeft(find.byType(OverviewTable)) + const Offset(250, 40),
      const Offset(-100, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(api.saveCount, 0);
  });
  testWidgets(
    'developer edits persist, conflict keeps draft, cancel does not write',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = OverviewApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: definitions,
              live: live,
              online: true,
              canEdit: true,
              stations: const ['A', 'B'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('temp-name'));
      await tester.enterText(name, '一次供温');
      api.conflict = true;
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(find.text('总览版本冲突，草稿保留'), findsOneWidget);
      expect(find.text('一次供温'), findsOneWidget);
      api.conflict = false;
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(api.config['columns'][0]['name'], '一次供温');
      expect(api.config['revision'], 2);
      final before = jsonEncode(api.config), writes = api.saveCount;
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.enterText(name, '不保存');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.config), before);
      expect(api.saveCount, writes);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('phone full menu and account actions stay reachable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 740);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? destination;
    var account = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: AndroidBottomNavigation(
              activePage: 11,
              onNavigate: (n) => destination = n,
              username: 'user001',
              onAccount: () => account = true,
              onLogout: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数据总览'), findsNothing);
    expect(
      find.byKey(const ValueKey('android-destination-16')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('数据总览')),
      matchesSemantics(
        label: '数据总览',
        isButton: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('android-destination-17')));
    await tester.pumpAndSettle();
    expect(destination, 17);
    expect(find.text('全部功能'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-destination--1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号安全'));
    await tester.pumpAndSettle();
    expect(account, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
