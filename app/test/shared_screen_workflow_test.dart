import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/features/process/screen_explorer.dart';
import 'package:universal_hmi/features/process/diagram.dart';
import 'package:universal_hmi/features/process/monitor.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;
import 'workspace_test.dart' show launch;

ScreenElement reading(String id) => ScreenElement.create(
  'value',
  const Offset(40, 40),
).update({'id': id, 'label': '供水压力'});
ScreenDocument instance({int layout = 1, List<ScreenElement>? nodes}) =>
    ScreenDocument(
      id: 'instance',
      name: '本站工艺',
      station: 'A',
      revision: 1,
      templateID: 'public',
      templateRevision: layout,
      nodes: nodes ?? [reading('reading')],
    );
Json resolved(ScreenDocument d) => {
  ...d.toJson(),
  'nodes': [for (final n in d.nodes) n.data],
  'assets': {},
};

class StationApi extends ScreenApi {
  final stations = <String>[];
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/stations') {
      if (method == 'POST') {
        final name = (body as Json)['name'] as String;
        stations.add(name);
        return {'name': name};
      }
      return {
        'items': [
          for (final name in stations) {'name': name},
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await processSymbols;
  });
  test(
    'instances serialize only own bindings and independent exports clear the shared identity',
    () {
      final d = instance(
        nodes: [
          reading('reading').update({'point_id': 'a'}),
        ],
      );
      final json = d.toJson();
      expect(json['nodes'], isEmpty);
      expect(json['assets'], isEmpty);
      expect(json['bindings']['reading']['point_id'], 'a');
      expect(json['template_id'], 'public');
      expect(d.instantiate('B').templateID, isEmpty);
      expect(d.toTemplate().templateRevision, 0);
      expect(d.toTemplate().nodes.single.pointID, isEmpty);
    },
  );

  testWidgets(
    'create station before any points, then add from the public screen without copying layout',
    (tester) async {
      final api = StationApi();
      api.screens['public'] = ScreenDocument(
        id: 'public',
        name: '公共供热',
        station: '',
        revision: 3,
        nodes: [reading('reading')],
      ).toJson();
      await launch(tester, api, size: const Size(1600, 1000));
      await tester.tap(find.byTooltip('新建站点'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'A',
      );
      await tester.tap(find.text('创建站点'));
      await tester.pumpAndSettle();
      expect(api.rows, isEmpty);
      expect(find.byKey(const Key('station-A')), findsOneWidget);
      await tester.tap(find.byTooltip('为 A 添加画面'));
      await tester.pumpAndSettle();
      expect(find.text('工艺图模板'), findsOneWidget);
      await tester.tap(find.byKey(const Key('template-shared-public')));
      await tester.pumpAndSettle();
      // Cross the 780px sidebar breakpoint while retaining the desktop toolbar.
      tester.view.physicalSize = const Size(779, 700);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1600, 1000);
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['template_id'], 'public');
      expect(api.savedScreen!['template_revision'], 3);
      expect(api.savedScreen!['station'], 'A');
      expect(api.savedScreen!['nodes'], isEmpty);
      expect(find.text('保存绑定'), findsOneWidget);
      expect(find.byTooltip('显示素材库'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'instance binding list includes authorized cross-station points and layout refresh preserves unsaved bindings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = ScreenApi();
      final session = ProcessSession('A')..loaded = true;
      session.controller.open(instance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
              session: session,
              station: 'A',
              definitions: const {
                'a': {'id': 'a', 'name': 'A 压力', 'station': 'A'},
                'b': {'id': 'b', 'name': 'B 私有压力', 'station': 'B'},
              },
              live: const {},
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('供水压力'));
      await tester.pumpAndSettle();
      expect(find.text('A 压力'), findsOneWidget);
      expect(find.text('B 私有压力'), findsOneWidget);
      await tester.tap(find.text('A 压力'));
      await tester.pumpAndSettle();
      expect(session.controller.document.nodes.single.pointID, 'a');
      api.screens['instance'] = resolved(
        instance(
          layout: 2,
          nodes: [
            reading('reading').update({'x': 90.0}),
            reading('new').update({'x': 300.0, 'label': '新增压力'}),
          ],
        ),
      );
      await tester.tap(find.text('同步公共布局'));
      await tester.pumpAndSettle();
      expect(session.controller.document.templateRevision, 2);
      expect(session.controller.document.nodes.first.x, 90);
      expect(session.controller.document.nodes.first.pointID, 'a');
      expect(session.controller.document.nodes.last.pointID, isEmpty);
      expect(session.controller.dirty, isTrue);
      await tester.enterText(find.byKey(const Key('screen-name')), 'A 供热监视');
      await tester.tap(find.text('保存绑定'));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['name'], 'A 供热监视');
      expect(api.savedScreen!['bindings']['reading']['point_id'], 'a');
      expect(api.savedScreen!['template_revision'], 2);
      expect(session.controller.dirty, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'running instance automatically reads a new public layout revision',
    (tester) async {
      final api = ScreenApi();
      api.screens['instance'] = resolved(instance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StationProcessView(
              api: api,
              station: 'A',
              initialScreenID: 'instance',
              definitions: const {},
              live: const {},
              online: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProcessDiagram>(find.byType(ProcessDiagram))
            .document
            .templateRevision,
        1,
      );
      api.screens['instance'] = resolved(
        instance(
          layout: 2,
          nodes: [
            reading('reading').update({'x': 150.0}),
          ],
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProcessDiagram>(find.byType(ProcessDiagram))
            .document
            .nodes
            .single
            .x,
        150,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collapse does not navigate away from the open station', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: ScreenExplorer(
              api: ScreenApi(),
              stations: const ['A'],
              station: 'A',
              development: true,
              onStation: (s) => selected = s,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('折叠 A'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.tap(find.byKey(const Key('station-A')));
    expect(selected, 'A');
    await tester.pumpWidget(const SizedBox());
  });
}
