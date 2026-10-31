import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/monitor.dart';
import 'package:universal_hmi/features/process/screen_explorer.dart';
import 'package:universal_hmi/features/process/page_navigation.dart';
import 'package:universal_hmi/features/process/templates.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'package:universal_hmi/main.dart';
import 'process_test.dart' show ScreenApi;

class MonitorApi extends ScreenApi {
  final calls = <String>[];
  Completer<Json>? delayedA;
  bool failMonitorRead = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    calls.add('$method $path');
    if (failMonitorRead) throw Exception('读取中断');
    if (path == '/api/v1/screens' &&
        query?['station'] == 'A' &&
        delayedA != null) {
      return delayedA!.future;
    }
    return super.request(method, path, body: body, query: query);
  }
}

ScreenDocument saved(String station, String id) => ScreenDocument(
  id: id,
  name: '$station 工艺图',
  station: station,
  revision: 1,
  nodes: [
    ScreenElement.create('value', const Offset(100, 100)).update({
      'id': '$id-reading',
      'point_id': '${station.toLowerCase()}-temp',
      'text': '$station ',
      'decimals': 1,
      'unit_override': '°C',
    }),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('process directory survives data page navigation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = MonitorApi();
    api.screens['a'] = saved('A', 'a').toJson();
    api.screens['b'] = saved('B', 'b').toJson();
    var page = 9;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, update) => HeatingMonitor(
            api: api,
            stations: const ['A', 'B'],
            station: 'A',
            onStationChanged: (_) {},
            onNavigate: (next) => update(() => page = next),
            activePage: page,
            userContent: page == 12 ? const Text('report-content') : null,
            definitions: const {},
            live: const {},
            online: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final explorer = tester.state(find.byType(ScreenExplorer));
    final tree = tester.state(find.byType(PageNavigationTree));
    final reads = api.calls.where((c) => c == 'GET /api/v1/navigation').length;
    await tester.enterText(
      find.byKey(const Key('monitor-station-search')),
      '工艺',
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('report-content'), findsOneWidget);
    await tester.tap(find.text('工艺画面').first);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ScreenExplorer)), same(explorer));
    expect(tester.state(find.byType(PageNavigationTree)), same(tree));
    expect(api.calls.where((c) => c == 'GET /api/v1/navigation').length, reads);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('monitor-station-search')))
          .controller!
          .text,
      '工艺',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('reporting the loaded screen does not blank and reload it', (
    tester,
  ) async {
    final api = MonitorApi();
    api.screens['A'] = saved('A', 'A').toJson();
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, update) => Scaffold(
            body: StationProcessView(
              api: api,
              station: 'A',
              initialScreenID: selected,
              definitions: const {},
              live: const {},
              online: true,
              onSelected: (id) => update(() => selected = id),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, 'A');
    expect(api.calls.where((c) => c == 'GET /api/v1/screens/A').length, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GIS launch stays on the map after point definitions arrive', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UniversalHmiApp(api: ScreenApi(), initialView: 'gis'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GisView), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(GisView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'GIS fills the viewport behind navigation; process retains its station tree',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = MonitorApi();
      var page = 11;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) => HeatingMonitor(
              api: api,
              stations: const ['A'],
              station: 'A',
              onStationChanged: (_) {},
              onNavigate: (next) => setState(() => page = next),
              definitions: const {},
              live: const {},
              online: true,
              showGis: page == 11,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.calls.every((c) => c.startsWith('GET ')), true);
      expect(
        tester
            .widget<Container>(
              find.byKey(const Key('monitor-header-background')),
            )
            .decoration,
        isNull,
      );
      expect(find.byKey(const Key('monitor-station-search')), findsNothing);
      expect(
        tester.getRect(find.byType(GisView)),
        const Rect.fromLTWH(0, 0, 1280, 800),
      );
      expect(find.byKey(const Key('monitor-current-station')), findsNothing);
      expect(find.text('用户画面 · 只读展示'), findsNothing);
      await tester.tap(find.text('工艺画面'));
      await tester.pumpAndSettle();
      expect(page, 9);
      expect(
        tester
            .widget<Container>(
              find.byKey(const Key('monitor-header-background')),
            )
            .decoration,
        isNotNull,
      );
      expect(find.byKey(const Key('monitor-station-search')), findsOneWidget);
      expect(find.byKey(const Key('monitor-current-station')), findsNothing);
      expect(find.byKey(const Key('monitor-reference-notice')), findsNothing);
      expect(find.text('用户画面 · 只读展示'), findsNothing);
      expect(find.text('运行监视'), findsNothing);
      expect(find.byKey(const Key('diagram-zoom-in')), findsNothing);
      expect(find.text('文字已缩小，可切换变量表或放大查看'), findsNothing);
      await tester.tap(find.text('GIS').first);
      await tester.pumpAndSettle();
      expect(page, 11);
      expect(find.byKey(const Key('monitor-station-search')), findsNothing);
      expect(api.calls.every((c) => c.startsWith('GET ')), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  setUpAll(() async {
    await ProcessSymbol.load();
    await ProcessTemplates.heatingMonitor('A');
  });
  test(
    'editable reference retains ports, units and no point or running bindings',
    () async {
      final a = await ProcessTemplates.heatingMonitor('A');
      final b = await ProcessTemplates.heatingMonitor('B');
      expect(a.id, isNot(b.id));
      expect(a.station, 'A');
      expect(a.nodes.every((n) => n.pointID.isEmpty), true);
      expect(
        a.nodes
            .where((n) => n.kind == 'value')
            .every((n) => n.label.isNotEmpty && n.unitOverride.isNotEmpty),
        true,
      );
      expect(
        a.nodes.where((n) => n.kind == 'pipe').every((n) => !n.arrowAnimate),
        true,
      );
      final hx = a.nodes.firstWhere((n) => n.id == 'heat-exchanger');
      expect(hx.symbol, 'monitor_hx_v2');
      expect(
        a.nodes.firstWhere((n) => n.id == 'tank').symbol,
        'monitor_tank_v2',
      );
      expect(
        a.nodes.firstWhere((n) => n.id == 'relief-valve').symbol,
        'monitor_relief',
      );
      expect(
        a.nodes.firstWhere((n) => n.id == 'primary-temperature-sensor').symbol,
        'monitor_temperature',
      );
      expect(
        a.nodes.firstWhere((n) => n.id == 'primary-pressure-sensor').symbol,
        'monitor_pressure_v2',
      );
      for (final pipe in a.nodes.where(
        (n) => n.kind == 'pipe' && (n.startNode == hx.id || n.endNode == hx.id),
      )) {
        expect(
          a.nodes.indexOf(pipe),
          greaterThan(a.nodes.indexOf(hx)),
          reason:
              'The visible pipe enters the bore above the opaque flange image',
        );
        final points = a.pipePoints(pipe);
        expect(
          pipe.startNode == hx.id ? points.first : points.last,
          a.port(
            hx.id,
            pipe.startNode == hx.id ? pipe.startPort : pipe.endPort,
          ),
        );
      }
      // PNG's transparent padding is not used as a physical connection edge.
      expect(a.port(hx.id, 'left_top').dx, greaterThan(hx.x));
      final moved = a.copy(
        nodes: [
          for (final n in a.nodes)
            n.id == hx.id
                ? n.update({
                    'x': hx.x + 15,
                    'width': hx.width * 1.2,
                    'rotation': 90,
                  })
                : n,
        ],
      );
      moved.checkGeometry();
      final incoming = moved.nodes.firstWhere((n) => n.id == 'primary-in');
      expect(moved.pipePoints(incoming).last, moved.port(hx.id, 'left_top'));
      expect(
        ScreenDocument.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Json,
        ).toJson(),
        a.toJson(),
      );
    },
  );

  testWidgets(
    'station list follows configured stations, filters and switches without writes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = MonitorApi();
      for (final s in ['A', 'B', 'C']) {
        api.screens[s] = saved(s, s).toJson();
      }
      String selected = 'A';
      List<String> stations = ['A', 'B', 'C'];
      Future<void> host() => tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) => HeatingMonitor(
              api: api,
              stations: stations,
              station: selected,
              onStationChanged: (s) => setState(() => selected = s),
              onNavigate: (_) {},
              definitions: const {
                'a-temp': {'station': 'A'},
                'b-temp': {'station': 'B'},
              },
              live: const {
                'a-temp': {'quality': 'good', 'value': 60.1},
                'b-temp': {'quality': 'good', 'value': 42.8},
              },
              online: true,
            ),
          ),
        ),
      );
      await host();
      await tester.pumpAndSettle();
      expect(find.text('公共画面'), findsNothing);
      expect(find.text('A 60.1 °C'), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigation-open-scope-B')));
      await tester.pumpAndSettle();
      expect(find.text('B 42.8 °C'), findsOneWidget);
      expect(find.text('A 60.1 °C'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('monitor-station-search')),
        'C',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('navigation-open-scope-C')), findsOneWidget);
      expect(find.byKey(const Key('navigation-open-scope-A')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('monitor-station-search')),
        '',
      );
      await tester.pumpAndSettle();
      stations = ['A', 'B'];
      await host();
      await tester.pumpAndSettle();
      // A screen-owned station remains visible even without live point definitions.
      expect(find.byKey(const Key('navigation-open-scope-C')), findsOneWidget);
      expect(find.text('设备操作'), findsNothing);
      expect(find.text('参数设定'), findsNothing);
      expect(api.calls.every((c) => c.startsWith('GET ')), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late A response cannot replace B and failed loads do not masquerade as references',
    (tester) async {
      final api = MonitorApi()..delayedA = Completer<Json>();
      api.screens['B'] = saved('B', 'B').toJson();
      Future<void> host(String station) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StationProcessView(
              api: api,
              station: station,
              definitions: const {
                'b-temp': {'station': 'B'},
              },
              live: const {
                'b-temp': {'quality': 'good', 'value': 42.8},
              },
              online: true,
            ),
          ),
        ),
      );
      await host('A');
      await tester.pump();
      await host('B');
      await tester.pumpAndSettle();
      api.delayedA!.complete({'items': []});
      await tester.pumpAndSettle();
      expect(find.text('B 42.8 °C'), findsOneWidget);
      expect(find.byKey(const Key('monitor-reference-notice')), findsNothing);
      api.failMonitorRead = true;
      await host('C');
      await tester.pumpAndSettle();
      expect(find.textContaining('画面读取失败'), findsOneWidget);
      expect(find.byKey(const Key('monitor-reference-notice')), findsNothing);
      api.failMonitorRead = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitor-empty-notice')), findsOneWidget);
      expect(find.text('— °C'), findsNothing);
      expect(find.byKey(const Key('monitor-empty-notice')), findsOneWidget);
      expect(api.calls.every((c) => c.startsWith('GET ')), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('narrow process pages open the directory and retain navigation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var station = '';
    var destination = 9;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, update) => HeatingMonitor(
            api: MonitorApi(),
            stations: const ['A', 'B'],
            station: station,
            onStationChanged: (next) => update(() => station = next),
            onNavigate: (next) => destination = next,
            definitions: const {},
            live: const {},
            online: true,
            activePage: 9,
            userContent: const Center(child: Text('report-content')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('runtime-toggle-menu')));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenExplorer), findsWidgets);
    await tester.tapAt(const Offset(590, 300));
    await tester.pumpAndSettle();
    expect(find.text('report-content'), findsOneWidget);
    expect(find.text('智慧供热集中监控系统'), findsOneWidget);
    await tester.ensureVisible(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(destination, 12);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'empty and narrow monitor retain access without layout overflow',
    (tester) async {
      for (final size in [const Size(600, 600), const Size(1180, 720)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            home: HeatingMonitor(
              api: MonitorApi(),
              stations: const [],
              station: '',
              onStationChanged: (_) {},
              onNavigate: (_) {},
              definitions: const {},
              live: const {},
              online: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('公共画面'), findsNothing);
        expect(find.text('开发工作台'), findsNothing);
        expect(find.byTooltip('开发页 · 公共工作台'), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
