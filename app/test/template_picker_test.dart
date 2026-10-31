import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/create_screen.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/templates.dart';
import 'package:universal_hmi/features/process/diagram.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class DelayedTemplateApi extends ScreenApi {
  final first = Completer<Json>();
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) => method == 'GET' && path == '/api/v1/screens/first'
      ? first.future
      : super.request(method, path, body: body, query: query);
}

Future<void> open(
  WidgetTester tester,
  ScreenApi api, {
  String station = 'A',
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => addScreen(context, api, station),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Json template(String id, String name, {int revision = 1}) => ScreenDocument(
  id: id,
  name: name,
  station: '',
  revision: revision,
  nodes: [ScreenElement.create('text', const Offset(40, 40))],
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await processSymbols;
    await ProcessTemplates.heatingMonitor('');
  });
  testWidgets(
    'large catalog search selects stable identity and refreshes revision on create',
    (tester) async {
      final api = ScreenApi();
      for (var i = 0; i < 120; i++) {
        api.screens['t$i'] = template('t$i', '公共模板 $i');
      }
      await open(tester, api);
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
      await tester.enterText(find.byKey(const Key('template-search')), '119');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-shared-t119')));
      await tester.pumpAndSettle();
      api.screens['t119'] = template('t119', '公共模板 119', revision: 4);
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['template_id'], 't119');
      expect(api.savedScreen!['template_revision'], 4);
      expect(api.savedScreen!['nodes'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switch templates keeps custom name and GIS has no template association',
    (tester) async {
      final api = ScreenApi();
      await open(tester, api, station: '');
      await tester.tap(find.byKey(const Key('template-builtin-blank')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('new-screen-name')), '自定义名称');
      await tester.tap(find.byKey(const Key('template-builtin-heating')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('new-screen-name')))
            .controller!
            .text,
        '自定义名称',
      );
      expect(
        tester
            .widget<ProcessDiagram>(find.byType(ProcessDiagram))
            .document
            .nodes,
        isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('screen-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GIS 地图').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('template-list')), findsNothing);
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['kind'], 'gis');
      expect(api.savedScreen!['station'], '');
      expect(api.savedScreen!['template_id'] ?? '', isEmpty);
      expect(api.savedScreen!['name'], '自定义名称');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('station creation only offers process screens', (tester) async {
    final api = ScreenApi();
    await open(tester, api);
    expect(find.text('GIS 是工程级公共驾驶舱，请在“公共画面”中创建。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('screen-kind')));
    await tester.pumpAndSettle();
    expect(find.text('GIS 地图'), findsNothing);
    expect(find.text('工艺图'), findsWidgets);
    expect(api.savedScreen, isNull);
  });

  testWidgets('late preview never replaces the latest selection', (
    tester,
  ) async {
    final api = DelayedTemplateApi();
    api.screens['first'] = template('first', '第一个');
    api.screens['second'] = template('second', '第二个');
    await open(tester, api);
    await tester.tap(find.byKey(const Key('template-shared-first')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('template-shared-second')));
    await tester.pumpAndSettle();
    api.first.complete(api.screens['first']);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProcessDiagram>(find.byType(ProcessDiagram)).document.id,
      'second',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.savedScreen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small dialog scrolls and empty search never selects an implicit template',
    (tester) async {
      final api = ScreenApi();
      await open(tester, api, station: '', size: const Size(640, 360));
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      expect(api.savedScreen, isNull);
      await tester.enterText(find.byKey(const Key('template-search')), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的模板，请调整搜索。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
