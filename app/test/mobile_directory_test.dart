import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/workspace.dart';
import 'package:universal_hmi/features/process/monitor.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/main.dart';
import 'heating_monitor_test.dart' show MonitorApi, saved;
import 'energy_statistics_test.dart' show EnergyApi, energy;
import 'external_data_test.dart' show ExternalApi, screen;

class MobileHistoryApi extends ExternalApi {
  bool emptyStations = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/external/screens') {
      return {
        'items': [
          screen,
          {...screen, 'id': 'second', 'name': '二号历史'},
        ],
      };
    }
    if (emptyStations && path.endsWith('/stations')) return {'items': <Json>[]};
    return super.request(method, path, body: body, query: query);
  }
}

class OrderedMobileApi extends MonitorApi {
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
            'id': 'group',
            'label': '现场站区',
            'children': [
              {'id': 'unavailable', 'label': '已失效', 'screen_id': 'missing'},
              {'id': 'second', 'label': '二号画面', 'screen_id': 'b'},
              {'id': 'first', 'label': '一号画面', 'screen_id': 'a'},
            ],
          },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

class MobileEnergyApi extends OrderedMobileApi {
  final energyApi = EnergyApi();
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (path == '/api/v1/external/screens') {
      return Future.value({
        'items': [
          energy,
          {...energy, 'id': 'energy-two', 'name': '二区能耗'},
          screen,
        ],
      });
    }
    if (path.startsWith('/api/v1/external/')) {
      return energyApi.request(method, path, body: body, query: query);
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'energy uses the shared bottom directory and preserves selection and query while hidden',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final api = MobileEnergyApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Workspace(
            api: api,
            canDevelop: false,
            canWrite: false,
            androidClient: true,
            initialView: 'runtime',
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<HeatingMonitor>(find.byType(HeatingMonitor)).onNavigate(18);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-directory-energy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('compact-directory-daily')),
        findsNothing,
      );
      expect(api.energyApi.queryCount, 1);
      await tester.tap(
        find.byKey(const ValueKey('compact-directory-energy-two')),
      );
      await tester.pumpAndSettle();
      expect(api.energyApi.queryCount, 2);
      await tester.enterText(
        find.byKey(const Key('compact-directory-search')),
        '二区',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-directory-energy')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('compact-directory-collapse')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobile-directory-restore')));
      await tester.pumpAndSettle();
      expect(find.text('二区'), findsOneWidget);
      expect(api.energyApi.queryCount, 2);
      await tester.tap(find.byKey(const Key('compact-directory-expand')));
      await tester.pumpAndSettle();
      expect(find.text('能耗目录'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      expect(api.energyApi.queryCount, 2);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<HeatingMonitor>(find.byType(HeatingMonitor)).activePage,
        18,
      );
      expect(find.byKey(const Key('mobile-directory-reduce')), findsNothing);
      expect(find.byKey(const Key('compact-directory-expand')), findsOneWidget);
      expect(api.energyApi.queryCount, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mobile return restores the previous module without logging out',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final api = OrderedMobileApi();
      var logouts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Workspace(
            api: api,
            canDevelop: false,
            canWrite: false,
            androidClient: true,
            initialView: 'runtime',
            onLogout: () => logouts++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      HeatingMonitor shell() =>
          tester.widget<HeatingMonitor>(find.byType(HeatingMonitor));
      expect(shell().activePage, 11);
      expect(find.byKey(const Key('mobile-page-back')), findsNothing);
      shell().onNavigate(17);
      await tester.pumpAndSettle();
      expect(shell().activePage, 17);
      shell().onNavigate(9);
      await tester.pumpAndSettle();
      expect(shell().activePage, 9);
      await tester.tap(find.byKey(const Key('mobile-page-back')));
      await tester.pumpAndSettle();
      expect(shell().activePage, 17);
      await tester.tap(find.byKey(const Key('mobile-page-back')));
      await tester.pumpAndSettle();
      expect(shell().activePage, 11);
      expect(find.byKey(const Key('mobile-page-back')), findsNothing);
      expect(logouts, 0);
      expect(api.calls.where((call) => !call.startsWith('GET ')), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone rail opens first valid ordered screen and switches directly without drawer',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final api = OrderedMobileApi();
      api.screens['a'] = saved('A', 'a').toJson();
      api.screens['b'] = saved('B', 'b').toJson();
      Json? selected;
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, update) => HeatingMonitor(
              api: api,
              androidClient: true,
              stations: const ['A', 'B'],
              station: 'A',
              selectedScreens: const {'A': 'a'},
              onStationChanged: (_) {},
              onNavigate: (_) {},
              definitions: const {},
              live: const {},
              online: true,
              activeScreen: selected,
              userContent: SizedBox.expand(
                key: const Key('mobile-content'),
                child: Text('${selected?['name'] ?? '载入中'}'),
              ),
              onOpenScreen: (screen) => update(() {
                selected = screen;
                opened.add('${screen['id']}');
              }),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, ['b']);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(find.byKey(const ValueKey('compact-directory-first')));
      await tester.pumpAndSettle();
      expect(opened, ['b', 'a']);
      expect(find.byType(Drawer), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('mobile-content'))).width,
        390,
      );
      final dock = tester.getRect(
        find.byKey(const Key('mobile-directory-dock')),
      );
      final content = tester.getRect(find.byKey(const Key('mobile-content')));
      final navigation = tester.getRect(
        find.byKey(const Key('android-navigation-surface')),
      );
      expect(content.bottom, dock.top);
      expect(dock.bottom, navigation.top);
      final expand = tester.getCenter(
        find.byKey(const Key('compact-directory-expand')),
      );
      final collapse = tester.getCenter(
        find.byKey(const Key('compact-directory-collapse')),
      );
      expect((expand - collapse).distance, lessThanOrEqualTo(56));
      final reads = api.calls.length;
      await tester.tap(find.byKey(const Key('compact-directory-collapse')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-directory-first')),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const Key('mobile-content'))).width,
        390,
      );
      expect(find.byKey(const Key('mobile-directory-restore')), findsOneWidget);
      final handle = find.byKey(const Key('mobile-directory-restore'));
      final before = tester.getTopLeft(handle);
      await tester.drag(handle, const Offset(-160, -130));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dx, lessThan(before.dx));
      expect(tester.getTopLeft(handle).dy, lessThan(before.dy));
      expect(find.byKey(const Key('mobile-directory-dock')), findsNothing);
      await tester.drag(handle, const Offset(-1000, 1000));
      await tester.pumpAndSettle();
      final moved = tester.getRect(handle);
      expect(moved.left, greaterThanOrEqualTo(0));
      expect(moved.bottom, lessThanOrEqualTo(navigation.top));
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(tester.getRect(handle).bottom, lessThanOrEqualTo(312));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobile-directory-restore')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('mobile-content'))).width,
        390,
      );
      expect(opened, ['b', 'a']);
      expect(api.calls.length, reads);
      await tester.tap(find.byKey(const Key('compact-directory-expand')));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byKey(const Key('mobile-directory-reduce')), findsOneWidget);
      expect(find.byKey(const Key('navigation-open-first')), findsOneWidget);
      expect(opened, ['b', 'a']);
      expect(api.calls.where((c) => !c.startsWith('GET ')), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone history opens first item, queries once, and keeps manual selection on rebuild',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final api = MobileHistoryApi();
      final catalog = ExternalCatalog(api, canDevelop: false);
      Json? selected;
      var expanded = false;
      final opens = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, update) => HeatingMonitor(
              api: api,
              androidClient: true,
              activePage: 12,
              stations: const [],
              station: '',
              onStationChanged: (_) {},
              onNavigate: (_) {},
              definitions: const {},
              live: const {},
              online: true,
              userSidebarBuilder: (_) => const Text('完整历史目录'),
              userCompactSidebarBuilder: (expand, collapse) =>
                  ExternalDataPanel(
                    catalog: catalog,
                    compact: true,
                    autoOpenFirst: true,
                    selectedID: selected?['id'] as String?,
                    onExpand: () {
                      expanded = true;
                      expand();
                    },
                    onCollapse: collapse,
                    onOpen: (s) => update(() {
                      selected = s;
                      opens.add('${s?['id']}');
                    }),
                  ),
              userContent: ExternalWorkspace(
                catalog: catalog,
                screen: selected,
                autoQuery: true,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, ['daily']);
      expect(api.bodies.length, 1);
      expect(api.bodies.single['station'], 'A');
      expect(api.bodies.single['mode'], 'hourly');
      expect(
        api.bodies.single['date'],
        DateTime.now().toIso8601String().substring(0, 10),
      );
      await tester.tap(find.byKey(const Key('compact-directory-expand')));
      await tester.pumpAndSettle();
      expect(expanded, isTrue);
      await tester.tap(find.byKey(const Key('mobile-directory-reduce')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('compact-directory-second')));
      await tester.pumpAndSettle();
      expect(opens, ['daily', 'second']);
      expect(api.bodies.length, 2);
      await tester.tap(find.byKey(const Key('compact-directory-collapse')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-directory-second')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('mobile-directory-restore')));
      await tester.pumpAndSettle();
      expect(opens, ['daily', 'second']);
      expect(api.bodies.length, 2);
      await catalog.load();
      await tester.pumpAndSettle();
      expect(opens, ['daily', 'second']);
      expect(api.bodies.length, 2);
      expect(api.calls.any((c) => c.endsWith('/sources')), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
  testWidgets(
    'automatic history query skips empty stations and does not retry a failure',
    (tester) async {
      final api = MobileHistoryApi()..emptyStations = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExternalQuery(api: api, screen: screen, autoQuery: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.bodies, isEmpty);
      await tester.pumpWidget(const SizedBox());
      api.emptyStations = false;
      api.fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExternalQuery(api: api, screen: screen, autoQuery: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.bodies.length, 1);
      expect(find.textContaining('测试查询失败'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(api.bodies.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
