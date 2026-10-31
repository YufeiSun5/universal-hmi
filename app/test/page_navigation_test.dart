import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/page_navigation.dart';
import 'package:universal_hmi/features/process/gis_screen.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class NavigationApi extends ScreenApi {
  Json config = {
    'revision': 1,
    'enabled': true,
    'nodes': <Json>[
      {
        'id': 'g',
        'label': '组',
        'children': <Json>[
          {'id': 'a', 'label': '第一', 'screen_id': 'a'},
          {'id': 'b', 'label': '第二', 'screen_id': 'b'},
        ],
      },
    ],
  };
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/navigation') {
      if (method == 'PUT') config = body as Json;
      return config;
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets('nested menu order and rename persist only after explicit save', (
    tester,
  ) async {
    final api = NavigationApi();
    final screens = <Json>[
      {'id': 'a', 'station': 'A', 'name': '工艺A'},
      {'id': 'b', 'station': 'B', 'name': '工艺B'},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageNavigationEditor(api: api, screens: screens),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上移').at(2));
    await tester.pump();
    await tester.tap(find.text('第二'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '第二改名');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect((api.config['nodes'] as List).first['children'][0]['label'], '第一');
    await tester.tap(find.text('保存菜单'));
    await tester.pumpAndSettle();
    final children = (api.config['nodes'] as List).first['children'] as List;
    expect(children.map((c) => c['screen_id']), ['b', 'a']);
    expect(children.first['label'], '第二改名');
  });
  testWidgets(
    'group opens first valid target every time; arrow only collapses; ownership stays independent',
    (tester) async {
      final opened = <Json>[];
      final nodes = <Json>[
        {
          'id': 'g',
          'label': '同一组',
          'children': <Json>[
            {'id': 'broken', 'label': '删除的画面', 'screen_id': 'missing'},
            {'id': 'a', 'label': '第一站', 'screen_id': 'a'},
            {'id': 'b', 'label': '第二站', 'screen_id': 'b'},
          ],
        },
      ];
      final screens = <Json>[
        {'id': 'a', 'station': '独立A站', 'name': 'A'},
        {'id': 'b', 'station': '独立B站', 'name': 'B'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageNavigationTree(
              nodes: nodes,
              screens: screens,
              onOpen: opened.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('navigation-open-g')));
      await tester.pump();
      expect(opened.last['station'], '独立A站');
      await tester.tap(find.byKey(const Key('navigation-open-b')));
      await tester.pump();
      expect(opened.last['station'], '独立B站');
      await tester.tap(find.byKey(const Key('navigation-toggle-g')));
      await tester.pump();
      expect(opened.length, 2);
      expect(find.byKey(const Key('navigation-open-b')), findsNothing);
      await tester.tap(find.byKey(const Key('navigation-open-g')));
      await tester.pump();
      expect(opened.last['id'], 'a');
      expect(find.byKey(const Key('navigation-open-b')), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigation-open-g')));
      await tester.pump();
      expect(opened.length, 4);
      await tester.tap(find.byKey(const Key('navigation-open-broken')));
      await tester.pump();
      expect(opened.length, 4);
      expect(find.textContaining('没有可用画面'), findsOneWidget);
    },
  );
  testWidgets(
    'GIS marker resolves configured screen identity and reports deleted target',
    (tester) async {
      final api = ScreenApi();
      final target = ScreenDocument(
        id: 'target',
        station: '另一站',
        name: '二次网',
      ).toJson();
      api.screens['target'] = target;
      final map = ScreenDocument(
        id: 'map',
        station: '',
        name: '首页',
        kind: 'gis',
        gis: {
          'stations': <Json>[
            {
              'id': 'pin',
              'name': '站标',
              'longitude': 122.0,
              'latitude': 39.0,
              'target_screen_id': 'target',
            },
          ],
        },
      ).toJson();
      api.screens['map'] = map;
      final opened = <Json>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GisScreen(api: api, summary: map, onOpenScreen: opened.add),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<GisView>(find.byType(GisView)).onOpenStation!('unknown');
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      tester.widget<GisView>(find.byType(GisView)).onOpenStation!('pin');
      await tester.pumpAndSettle();
      expect(opened.single['station'], '另一站');
      api.screens.remove('target');
      tester.widget<GisView>(find.byType(GisView)).onOpenStation!('pin');
      await tester.pumpAndSettle();
      expect(opened.length, 1);
      expect(find.textContaining('无法打开目标'), findsOneWidget);
    },
  );
}
