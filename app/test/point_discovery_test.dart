import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/point_discovery.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'workspace_test.dart' show FakeApi;

class DiscoveryApi extends FakeApi {
  final catalogue = <String, List<Json>>{};
  final connected = <String>{};
  final batches = <List<Json>>[];
  final connections = <String>[];
  Completer<Json>? delayedA;
  Completer<Json>? delayedSelection;
  bool changeRevision = false;
  int discoveryReads = 0;
  Json item(
    String path,
    String type, {
    String existing = '',
    String status = 'inferred',
  }) => {
    'path': path,
    'name': path,
    'topic': 'data',
    'data_type': type,
    'type_status': status,
    'preview': type == 'BOOL' ? 'false' : '12',
    'quality': 'good',
    'existing_id': existing,
    'existing_station': 'A',
  };
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/discovery')) {
      discoveryReads++;
      final id = path.split('/')[4];
      if (id == 'a' && delayedA != null) return delayedA!.future;
      if (query?['limit'] == 500 && delayedSelection != null) {
        return delayedSelection!.future;
      }
      final all = catalogue[id] ?? [];
      final q = '${query?['q'] ?? ''}'.toLowerCase();
      final patterns = q
          .split(RegExp('[,，\\n]'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      final found = all
          .where(
            (r) =>
                q.isEmpty ||
                patterns.any((part) {
                  final value = '${r['path']}'.toLowerCase();
                  if (!part.contains(RegExp(r'[*?]'))) {
                    return value.contains(part);
                  }
                  final expression = RegExp.escape(
                    part,
                  ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
                  return RegExp('^$expression\$').hasMatch(value);
                }),
          )
          .toList();
      return {
        'items': found
            .skip(query?['offset'] as int? ?? 0)
            .take(query?['limit'] as int? ?? 200)
            .toList(),
        'revision': changeRevision ? '$discoveryReads' : 'stable',
        'connected': connected.contains(id),
        'total': found.length,
        'observed': all.length,
        'metrics': <String, dynamic>{},
      };
    }
    if (path.endsWith('/connect')) {
      final id = path.split('/')[4];
      connections.add(id);
      connected.add(id);
      return {'connected': true};
    }
    if (path == '/api/v1/points/batch') {
      final items = objects((body as Json)['items']);
      batches.add(items);
      return {'items': items};
    }
    return super.request(method, path, body: body, query: query);
  }
}

Future<void> openDiscovery(
  WidgetTester tester,
  DiscoveryApi api, {
  Size size = const Size(1100, 850),
  String station = 'A',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => discoverPoints(
              context,
              api,
              sources: [
                {'id': 'a', 'name': '来源 A', 'protocol': 'generic'},
                {'id': 'b', 'name': '来源 B', 'protocol': 'kingio'},
              ],
              stations: ['A', 'B'],
              station: station,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'question and comma alternatives select matches, changing source resets old choices',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [
        api.item('泵1运行', 'BOOL'),
        api.item('泵12运行', 'BOOL'),
        api.item('供水温度', 'FLOAT'),
      ];
      api.catalogue['b'] = [api.item('泵2运行', 'BOOL')];
      await openDiscovery(tester, api);
      await tester.enterText(
        find.byKey(const Key('discovery-search')),
        '泵?运行，*温度*',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (2)'), findsOneWidget);
      expect(find.text('泵12运行'), findsNothing);
      await tester.tap(find.byKey(const Key('discovery-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源 B · kingio').last);
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (1)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(api.batches.single.single['source_id'], 'b');
      expect(api.batches.single.single['source_path'], '泵2运行');
    },
  );

  testWidgets('cancel all-selection ignores its late result', (tester) async {
    final api = DiscoveryApi();
    api.catalogue['a'] = [api.item('First', 'FLOAT')];
    await openDiscovery(tester, api);
    api.delayedSelection = Completer<Json>();
    await tester.tap(find.byKey(const Key('discovery-select-all')));
    await tester.pump();
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    api.delayedSelection!.complete({
      'items': [api.item('Late', 'FLOAT')],
      'total': 1,
      'revision': 'new',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discovery-add')));
    await tester.pumpAndSettle();
    expect(api.batches.single.single['source_path'], 'First');
  });
  testWidgets(
    'star selects across pages, excludes existing and unknown, saves one batch',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [
        for (var i = 0; i < 605; i++) api.item('Heat.T$i', 'FLOAT'),
        api.item('Old', 'BOOL', existing: 'old'),
        api.item('Unknown', ''),
      ];
      await openDiscovery(tester, api);
      await tester.enterText(find.byKey(const Key('discovery-search')), '*');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (605)'), findsOneWidget);
      expect(find.textContaining('跳过已添加 1 项、类型待确认 1 项'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (605)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(api.batches.single.length, 605);
      expect(
        api.batches.single.map((p) => p['source_path']).toSet().length,
        605,
      );
      expect(api.applied, 0);
    },
  );

  testWidgets(
    'wildcard filter and manual deselection survive pagination, clear stays clear',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [
        for (var i = 0; i < 250; i++) api.item('Heat.T$i', 'FLOAT'),
        api.item('Other', 'BOOL'),
      ];
      await openDiscovery(tester, api);
      await tester.enterText(
        find.byKey(const Key('discovery-search')),
        'Heat.*',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (250)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('discovery-check-Heat.T0')));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (249)'), findsOneWidget);
      await tester.tap(find.text('上一页'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('discovery-check-Heat.T0')),
            )
            .value,
        false,
      );
      await tester.tap(find.text('清空选择'));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (0)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discovery-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (250)'), findsOneWidget);
    },
  );

  testWidgets(
    'changing catalogue rejects incomplete all-selection without losing old choices',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [
        for (var i = 0; i < 600; i++) api.item('T$i', 'FLOAT'),
      ];
      await openDiscovery(tester, api);
      api.changeRevision = true;
      await tester.tap(find.byKey(const Key('discovery-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (200)'), findsOneWidget);
      expect(find.textContaining('全选未完成'), findsOneWidget);
      expect(api.batches, isEmpty);
    },
  );
  testWidgets(
    'scan filters, skips existing variables, saves readonly batch without applying',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [
        api.item('Heat.Temp', 'FLOAT'),
        api.item('Heat.Run', 'BOOL'),
        api.item('Old', 'STRING', existing: 'old'),
      ];
      await openDiscovery(tester, api, station: '');
      expect(api.connections, isEmpty); // Opening is read-only.
      expect(find.text('添加选中 (2)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(api.batches, isEmpty);
      expect(find.textContaining('请选择或输入有效'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('discovery-station')), 'B');
      await tester.enterText(find.byKey(const Key('discovery-search')), 'temp');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('添加选中 (1)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(
        api.batches.single.single,
        containsPair('source_path', 'Heat.Temp'),
      );
      expect(api.batches.single.single, containsPair('station', 'B'));
      expect(api.batches.single.single, containsPair('data_type', 'FLOAT'));
      expect(api.batches.single.single, containsPair('writable', false));
      expect(api.applied, 0);
      expect(find.byType(PointDiscoveryDialog), findsNothing);
    },
  );

  testWidgets(
    'unknown types need confirmation and duplicate names do not partially save',
    (tester) async {
      final api = DiscoveryApi();
      api.catalogue['a'] = [api.item('Mystery', '', status: 'conflict')];
      api.rows.add(api.point('p', 'A')..['name'] = 'Mystery');
      await openDiscovery(tester, api);
      expect(find.text('添加选中 (0)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('discovery-type-Mystery')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('字符串').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(api.batches, isEmpty);
      expect(find.textContaining('站点内名称重复'), findsOneWidget);
      await tester.tap(find.byTooltip('修改变量名称'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('discovery-name')),
        'Renamed',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      expect(api.batches.single.single['name'], 'Renamed');
      expect(api.batches.single.single['data_type'], 'STRING');
    },
  );

  testWidgets('late source result cannot replace the newly selected source', (
    tester,
  ) async {
    final api = DiscoveryApi()..delayedA = Completer<Json>();
    api.catalogue['b'] = [api.item('B.Value', 'FLOAT')];
    // A pending progress indicator prevents pumpAndSettle.
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: PointDiscoveryDialog(
          api: api,
          sources: [
            {'id': 'a', 'name': '来源 A', 'protocol': 'generic'},
            {'id': 'b', 'name': '来源 B', 'protocol': 'generic'},
          ],
          stations: ['A'],
          station: 'A',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('discovery-source')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('来源 B · generic').last);
    await tester.pumpAndSettle();
    api.delayedA!.complete({
      'items': [api.item('A.Wrong', 'BOOL')],
      'total': 1,
    });
    await tester.pumpAndSettle();
    expect(find.text('B.Value'), findsOneWidget);
    expect(find.text('A.Wrong'), findsNothing);
  });

  testWidgets(
    'small window keeps actions accessible and scanning connects only on request',
    (tester) async {
      final api = DiscoveryApi();
      await openDiscovery(tester, api, size: const Size(640, 300));
      expect(tester.takeException(), isNull);
      expect(api.connections, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('discovery-scan')));
      await tester.tap(find.byKey(const Key('discovery-scan')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.connections, ['a']);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 9));
      expect(tester.takeException(), isNull);
      expect(find.byType(PointDiscoveryDialog), findsNothing);
    },
  );
}
