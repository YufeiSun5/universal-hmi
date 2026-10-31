import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/screen_explorer.dart';
import 'package:universal_hmi/features/process/page_navigation.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class DelayedIndexApi extends ScreenApi {
  final index = Completer<Json>();
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) => method == 'GET' && path == '/api/v1/screens'
      ? index.future
      : super.request(method, path, body: body, query: query);
}

class DirectoryReadApi extends ScreenApi {
  int directoryReads = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (path == '/api/v1/screens' && query?['all'] == true) {
      directoryReads++;
    }
    return super.request(method, path, body: body, query: query);
  }
}

class NestedNavigationApi extends ScreenApi {
  String group = '区域一';
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/navigation') {
      return {
        'enabled': true,
        'nodes': [
          {
            'id': 'g',
            'label': group,
            'children': [
              {'id': 'child', 'label': '泵房入口', 'screen_id': 'a'},
            ],
          },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets('客户端分级搜索与刷新菜单，开发端仍按真实站平铺', (tester) async {
    final api = NestedNavigationApi();
    api.screens['a'] = ScreenDocument(
      id: 'a',
      station: '真实站',
      name: '泵房',
    ).toJson();
    Json? opened;
    var revision = 0;
    var development = false;
    await tester.binding.setSurfaceSize(const Size(800, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, update) => Scaffold(
            appBar: AppBar(
              actions: [
                TextButton(
                  onPressed: () => update(() => development = true),
                  child: const Text('开发端'),
                ),
              ],
            ),
            body: SizedBox(
              width: 240,
              child: ScreenExplorer(
                api: api,
                stations: const ['真实站'],
                station: '真实站',
                development: development,
                kindFilter: 'process',
                refreshRevision: revision,
                onStation: (_) {},
                onOpen: (v) => opened = v,
              ),
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: () => update(() {
                revision++;
              }),
              child: const Icon(Icons.refresh),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('monitor-station-search')),
      '泵房入口',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('navigation-open-child')));
    expect(opened?['station'], '真实站');
    await tester.enterText(find.byKey(const Key('monitor-station-search')), '');
    api.group = '区域二';
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('区域二'), findsOneWidget);
    await tester.tap(find.text('开发端'));
    await tester.pumpAndSettle();
    expect(find.text('真实站'), findsOneWidget);
    expect(find.byKey(const Key('screen-resource-a')), findsOneWidget);
    expect(find.text('区域二'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'switching process screens keeps the directory without refetching',
    (tester) async {
      final api = DirectoryReadApi();
      for (final id in ['a', 'b']) {
        api.screens[id] = ScreenDocument(
          id: id,
          station: 'A',
          name: '工艺$id',
        ).toJson();
      }
      var selected = 'a';
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, update) => Scaffold(
              body: SizedBox(
                width: 248,
                child: ScreenExplorer(
                  api: api,
                  stations: const ['A'],
                  station: 'A',
                  kindFilter: 'process',
                  selectedID: selected,
                  onStation: (_) {},
                  onOpen: (screen) =>
                      update(() => selected = screen['id'] as String),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.directoryReads, 1);
      final tree = tester.state(find.byType(PageNavigationTree));
      await tester.enterText(
        find.byKey(const Key('monitor-station-search')),
        '工艺',
      );
      await tester.tap(find.byKey(const Key('navigation-open-screen-b')));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(api.directoryReads, 1);
      expect(tester.state(find.byType(PageNavigationTree)), same(tree));
      expect(find.text('工艺a'), findsOneWidget);
      expect(find.text('工艺b'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('monitor-station-search')))
            .controller!
            .text,
        '工艺',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'loading the directory never exposes a temporary default GIS tab',
    (tester) async {
      final api = DelayedIndexApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenExplorer(
              api: api,
              stations: const [],
              station: '',
              development: true,
              onStation: (_) {},
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('screen-resource-')), findsNothing);
      api.index.complete({
        'items': [
          ScreenDocument(
            id: 'saved-map',
            name: '已保存地图',
            station: '',
            kind: 'gis',
          ).toJson(),
        ],
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen-resource-')), findsNothing);
      expect(
        find.byKey(const Key('screen-resource-saved-map')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'developer manually adds public GIS and reopens a station GIS without changing its scope',
    (tester) async {
      final api = ScreenApi();
      final station = ScreenDocument(
        id: 'station-map',
        name: 'A 站地图',
        station: 'A',
        kind: 'gis',
      ).toJson();
      api.screens['station-map'] = station;
      Json? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 218,
              child: ScreenExplorer(
                api: api,
                stations: const ['A'],
                station: '',
                development: true,
                canWrite: true,
                onStation: (_) {},
                onOpen: (d) => opened = d,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建公共画面'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('screen-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GIS 地图').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '公共地图',
      );
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(opened?['kind'], 'gis');
      expect(opened?['station'], '');
      expect(api.screens.length, 2);
      await tester.tap(find.byKey(const Key('screen-resource-station-map')));
      await tester.pumpAndSettle();
      expect(opened?['station'], 'A');
      expect(opened?['kind'], 'gis');
      expect(api.screens['station-map'], station);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'user resource tree has no mutation controls and global developer destination does not select a station',
    (tester) async {
      final api = ScreenApi();
      int? destination;
      String? station;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                WorkspaceActivityRail(
                  selectedPanel: 0,
                  onSelect: (value) => destination = value,
                ),
                SizedBox(
                  width: 218,
                  child: ScreenExplorer(
                    api: api,
                    stations: const ['A'],
                    station: 'A',
                    onStation: (value) => station = value,
                    onOpen: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('添加公共或站点画面'), findsNothing);
      await tester.tap(find.byTooltip('资源管理器'));
      expect(destination, 0);
      expect(station, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
