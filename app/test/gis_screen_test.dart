import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/gis_screen.dart';
import 'package:universal_hmi/features/process/gis_bindings.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'process_test.dart' show ScreenApi;
import 'package:universal_hmi/features/process/subscriptions.dart';

void main() {
  test('zone subscriptions deduplicate shared IDs and retain bad quality', () {
    final config = <String, dynamic>{
      'stations': [
        {
          'bindings': {'primary_supply': 'common'},
          'zones': [
            {
              'id': 'z1',
              'name': '一区',
              'bindings': {
                'primary_supply': 'common',
                'secondary_supply': 'zone',
              },
            },
            {
              'id': 'z2',
              'name': '二区',
              'bindings': {'supply_pressure': 'zone'},
            },
          ],
        },
      ],
    };
    expect(gisSubscriptionIDs(config), {'common', 'zone'});
    final values = gisReadings(
      config,
      {
        'common': {'name': '公共'},
        'zone': {'name': '分区'},
      },
      {
        'common': {'value': 42, 'quality': 'good'},
        'zone': {'value': 0, 'quality': 'bad'},
      },
      true,
    );
    expect(values['common']['text'], '42.00');
    expect(values['zone']['quality'], 'bad');
    expect(values['zone']['text'], '—');
  });
  testWidgets('GIS zones add rename reorder cancel save and reopen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ScreenApi();
    final source = ScreenDocument(
      id: 'gis-zones',
      name: '地图',
      station: '',
      kind: 'gis',
      gis: {
        'stations': [
          {
            'id': 'map',
            'name': '站',
            'longitude': 122.9,
            'latitude': 39.7,
            'bindings': {'primary_supply': 'p'},
            'zones': [
              {
                'id': 'old',
                'name': '原分区',
                'bindings': {'supply_pressure': 'p'},
              },
            ],
          },
        ],
      },
    ).toJson();
    api.screens['gis-zones'] = source;
    final drafts = <String, GisDraft>{};
    Widget build() => MaterialApp(
      home: Scaffold(
        body: GisScreen(
          api: api,
          summary: source,
          editing: true,
          canWrite: true,
          drafts: drafts,
          definitions: const {
            'p': {'station': '站', 'name': '压力'},
          },
        ),
      ),
    );
    Future<void> tapVisible(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    tester.widget<GisView>(find.byType(GisView)).onEditStation!('map');
    await tester.pumpAndSettle();
    await tapVisible(find.text('添加分区'));
    await tapVisible(find.text('2. 分区 2'));
    final name = find.widgetWithText(TextFormField, '分区名称');
    await tester.ensureVisible(name);
    await tester.enterText(name, '新增四区');
    await tester.pumpAndSettle();
    await tapVisible(find.text('上移').last);
    await tapVisible(find.text('确定'));
    expect(api.savedScreen, isNull);
    final zoneList = drafts['gis-zones']!.config!['stations'][0]['zones'];
    expect(zoneList[0]['name'], '新增四区');
    expect(zoneList[1]['id'], 'old');
    tester.widget<GisView>(find.byType(GisView)).onEditStation!('map');
    await tester.pumpAndSettle();
    await tapVisible(find.text('2. 原分区'));
    await tapVisible(find.text('删除分区'));
    await tapVisible(find.text('取消'));
    expect(drafts['gis-zones']!.config!['stations'][0]['zones'], hasLength(2));
    await tapVisible(find.text('保存画面'));
    expect(
      api.savedScreen!['gis']['stations'][0]['bindings']['primary_supply'],
      'p',
    );
    expect(
      api.savedScreen!['gis']['stations'][0]['zones'][1]['bindings']['supply_pressure'],
      'p',
    );
    await tester.pumpWidget(const SizedBox());
    drafts.clear();
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GisView>(find.byType(GisView))
          .config!['stations'][0]['zones'][0]['name'],
      '新增四区',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'GIS binding wildcard alternatives match names and source paths',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GisPointPicker(
              definitions: const {
                't': {'name': '供水温度', 'station': '一区', 'source_path': 'KIO.温度'},
                'p': {'name': '回水压力', 'station': '二区', 'source_path': 'KIO.压力'},
                'x': {'name': '循环泵', 'station': '三区', 'source_path': 'KIO.泵1'},
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '*温度*,*压力*');
      await tester.pumpAndSettle();
      expect(find.text('一区 / 供水温度'), findsOneWidget);
      expect(find.text('二区 / 回水压力'), findsOneWidget);
      expect(find.text('三区 / 循环泵'), findsNothing);
      await tester.enterText(find.byType(TextField), 'KIO.泵?');
      await tester.pumpAndSettle();
      expect(find.text('三区 / 循环泵'), findsOneWidget);
      expect(find.text('一区 / 供水温度'), findsNothing);
    },
  );

  testWidgets(
    'external dialogs and menus suspend GIS while the top preview stays interactive',
    (tester) async {
      final api = ScreenApi();
      final source = ScreenDocument(
        id: 'modal-map',
        name: '地图',
        station: '',
        kind: 'gis',
        gis: {'stations': <Json>[]},
      ).toJson();
      api.screens['modal-map'] = source;
      final navigator = GlobalKey<NavigatorState>();
      const baseKey = Key('base-map'), previewKey = Key('preview-map');
      Widget map(Key key) => GisScreen(key: key, api: api, summary: source);
      bool interactive(Key key) => tester
          .widget<GisView>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(GisView),
            ),
          )
          .interactive;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: map(baseKey)),
        ),
      );
      await tester.pumpAndSettle();
      expect(interactive(baseKey), true);

      showDialog<void>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          title: const Text('外部确认'),
          content: DropdownButton<String>(
            value: 'A',
            items: const [
              DropdownMenuItem(value: 'A', child: Text('选项 A')),
              DropdownMenuItem(value: 'B', child: Text('选项 B')),
            ],
            onChanged: (_) {},
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      await tester.tap(find.text('选项 B').last);
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(interactive(baseKey), true);

      showMenu<String>(
        context: navigator.currentContext!,
        position: const RelativeRect.fromLTRB(20, 20, 600, 400),
        items: const [PopupMenuItem(value: 'open', child: Text('菜单项'))],
      );
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      await tester.tap(find.text('菜单项'));
      await tester.pumpAndSettle();
      expect(interactive(baseKey), true);

      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => Dialog(
          child: SizedBox(width: 500, height: 300, child: map(previewKey)),
        ),
      );
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      expect(interactive(previewKey), true);
      showDialog<void>(
        context: tester.element(find.byKey(previewKey)),
        builder: (_) => const AlertDialog(title: Text('预览上的确认')),
      );
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      expect(interactive(previewKey), false);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(interactive(baseKey), false);
      expect(interactive(previewKey), true);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(interactive(baseKey), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('GIS references only stable IDs and preserves quality and units', () {
    final config = <String, dynamic>{
      'stations': [
        {
          'bindings': {'primary_supply': 'b'},
        },
      ],
    };
    final definitions = <String, Json>{
      'a': {'name': '温度', 'station': 'A', 'unit': '°C'},
      'b': {'name': '温度', 'station': 'B', 'unit': '°C'},
    };
    final live = <String, Json>{
      'a': {'value': 99, 'quality': 'good'},
      'b': {'value': 42.25, 'quality': 'good'},
    };
    expect(gisReadings(config, definitions, live, true)['b']['text'], '42.25');
    expect(
      gisReadings(config, definitions, live, true).containsKey('a'),
      false,
    );
    for (final quality in ['bad', 'stale', 'uncertain']) {
      live['b']!['quality'] = quality;
      expect(gisReadings(config, definitions, live, true)['b']['text'], '—');
    }
    live['b']!['quality'] = 'good';
    expect(
      gisReadings(config, definitions, live, false)['b']['quality'],
      'offline',
    );
    expect(gisReadings(config, {}, live, true)['b']['quality'], 'missing');
    live['b']!['value'] = 'bad numeric';
    expect(
      gisReadings(config, definitions, live, true)['b']['quality'],
      'unsupported',
    );
  });
  testWidgets(
    'GIS card binding selects cross-station ID, cancels safely, saves and reopens',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ScreenApi();
      final source = ScreenDocument(
        id: 'gis',
        name: '地图',
        station: '',
        kind: 'gis',
        gis: {
          'stations': [
            {
              'id': 'map-a',
              'name': '地图站',
              'longitude': 122.9,
              'latitude': 39.7,
            },
          ],
        },
      ).toJson();
      api.screens['gis'] = source;
      final definitions = <String, Json>{
        'a': {'station': 'A', 'name': '同名温度'},
        'b': {'station': 'B', 'name': '同名温度'},
      };
      final drafts = <String, GisDraft>{};
      Widget build() => MaterialApp(
        home: Scaffold(
          body: GisScreen(
            api: api,
            summary: source,
            editing: true,
            canWrite: true,
            drafts: drafts,
            definitions: definitions,
          ),
        ),
      );
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      tester.widget<GisView>(find.byType(GisView)).onEditStation!('map-a');
      await tester.pumpAndSettle();
      expect(tester.widget<GisView>(find.byType(GisView)).interactive, false);
      await tester.tap(find.text('一次侧供水温度'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'B');
      await tester.pumpAndSettle();
      expect(find.text('A / 同名温度'), findsNothing);
      await tester.tap(find.text('B / 同名温度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(api.savedScreen, isNull);
      expect(
        drafts['gis']!.config!['stations'][0]['bindings']['primary_supply'],
        'b',
      );
      final map = tester.widget<GisView>(find.byType(GisView));
      expect(map.interactive, true);
      map.onEditStation!('map-a');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清除一次侧供水温度绑定'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        drafts['gis']!.config!['stations'][0]['bindings']['primary_supply'],
        'b',
      );
      await tester.tap(find.text('保存画面'));
      await tester.pumpAndSettle();
      expect(
        api.savedScreen!['gis']['stations'][0]['bindings']['primary_supply'],
        'b',
      );
      await tester.pumpWidget(const SizedBox());
      drafts.clear();
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GisView>(find.byType(GisView))
            .config!['stations'][0]['bindings']['primary_supply'],
        'b',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'GIS edits remain drafts until saved; preview and client cannot mutate',
    (tester) async {
      final api = ScreenApi();
      final source = ScreenDocument(
        id: 'gis',
        name: '公共地图',
        station: '',
        kind: 'gis',
        gis: {'stations': <Object>[]},
      ).toJson();
      api.screens['gis'] = source;
      final drafts = <String, GisDraft>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GisScreen(
              api: api,
              summary: source,
              editing: true,
              canWrite: true,
              drafts: drafts,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加站点'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '新增站');
      await tester.enterText(find.byType(TextFormField).at(1), '181');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入 -180.0'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(1), '122.93');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(api.savedScreen, isNull);
      expect(drafts['gis']!.dirty, true);
      final map = tester.widget<GisView>(find.byType(GisView));
      map.onChanged!({
        'stations': [
          {'id': 'moved', 'name': '移动站', 'longitude': 122.95, 'latitude': 39.7},
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('添加站点'), findsNothing);
      expect(tester.widget<GisView>(find.byType(GisView)).editable, false);
      await tester.tap(find.text('返回编辑'));
      await tester.pumpAndSettle();
      api.conflict = true;
      await tester.tap(find.text('保存画面'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败，草稿已保留'), findsOneWidget);
      expect(drafts['gis']!.dirty, true);
      api.conflict = false;
      await tester.tap(find.text('保存画面'));
      await tester.pumpAndSettle();
      expect(drafts['gis']!.dirty, false);
      expect(api.savedScreen!['gis']['stations'][0]['longitude'], 122.95);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GisScreen(api: api, summary: source),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保存画面'), findsNothing);
      expect(find.byTooltip('添加站点'), findsNothing);
      expect(tester.widget<GisView>(find.byType(GisView)).editable, false);
      expect(
        tester
            .widget<GisView>(find.byType(GisView))
            .config!['stations'][0]['longitude'],
        122.95,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
