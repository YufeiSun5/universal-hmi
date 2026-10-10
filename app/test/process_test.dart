import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/symbol_sizes.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi, launch;

class ScreenApi extends FakeApi {
  Json? savedScreen;
  final screens = <String, Json>{};
  bool conflict = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/screens') {
      return {
        'items': [
          for (final s in screens.values)
            if (s['station'] == query?['station']) s,
        ],
      };
    }
    if (path.startsWith('/api/v1/screens/') && method == 'GET') {
      return jsonDecode(jsonEncode(screens[path.split('/').last])) as Json;
    }
    if (path.startsWith('/api/v1/screens/') && method == 'PUT') {
      if (conflict) throw const PlatformRequestException(409, '画面版本冲突');
      savedScreen = jsonDecode(jsonEncode(body)) as Json;
      final saved = <String, dynamic>{
        ...savedScreen!,
        'revision': (savedScreen!['revision'] as int) + 1,
      };
      screens[saved['id'] as String] = saved;
      return saved;
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all 458 external and four original process SVGs compile into real pictures',
    () async {
      final catalog = await ProcessSymbol.load();
      expect(catalog.length, 462);
      for (final s in catalog) {
        final xml = await rootBundle.loadString(s.path);
        expect(xml, isNot(contains('<script')), reason: s.path);
        final picture = await vg.loadPicture(SvgStringLoader(xml), null);
        expect(picture.size.isEmpty, false, reason: s.path);
        final expected = processSymbolSizes[s.id]!;
        // The vector-graphics codec stores sizes as float32; the generated
        // coordinates retain the original viewBox's double precision.
        expect(
          picture.size.width,
          closeTo(expected.width, expected.width * 1e-6),
          reason: s.path,
        );
        expect(
          picture.size.height,
          closeTo(expected.height, expected.height * 1e-6),
          reason: s.path,
        );
        picture.picture.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'connected pipes follow moved equipment, deletion freezes geometry and undo restores links',
    () {
      final editor = ProcessController(ScreenDocument.empty('A'));
      final a = ScreenElement.create('rect', const Offset(100, 100));
      final b = ScreenElement.create('rect', const Offset(400, 100));
      editor.add(a);
      editor.add(b);
      editor.addPipe(
        [a.rect.centerRight, b.rect.centerLeft],
        start: (a.id, 'right', a.rect.centerRight),
        end: (b.id, 'left', b.rect.centerLeft),
      );
      final pipe = editor.selected!;
      editor.update(b.update({'y': 300.0}));
      final points = editor.document.pipePoints(pipe);
      expect(points.first, a.rect.centerRight);
      expect(points.last, const Offset(400, 350));
      for (var i = 1; i < points.length; i++) {
        expect(
          points[i].dx == points[i - 1].dx || points[i].dy == points[i - 1].dy,
          true,
        );
      }
      editor.select(b.id);
      editor.removeSelected();
      final detached = editor.document.nodes.firstWhere((n) => n.id == pipe.id);
      expect(detached.endNode, '');
      expect(detached.points, points);
      editor.undo();
      expect(
        editor.document.nodes.firstWhere((n) => n.id == pipe.id).endNode,
        b.id,
      );
      editor.document.checkGeometry();
      editor.dispose();
    },
  );

  test(
    'image clipboard, revision after undo and read-only preview preserve documents',
    () {
      final editor = ProcessController(ScreenDocument.empty('A'));
      final image = ScreenElement.create(
        'image',
        const Offset(100, 100),
        image: 'asset',
      );
      final asset = EmbeddedImage('image.png', 'image/png', 'aGVsbG8=');
      editor.add(image, assets: {'asset': asset});
      editor.saved(1);
      editor.copy();
      editor.removeSelected();
      expect(editor.document.assets, isEmpty);
      editor.paste();
      expect(editor.document.assets['asset'], asset);
      editor.saved(2);
      editor.undo();
      expect(editor.document.revision, 2);
      editor.redo();
      expect(editor.dirty, false);
      editor.editing = false;
      final before = editor.document;
      editor.move(const Offset(10, 10));
      editor.removeSelected();
      editor.paste();
      editor.undo();
      expect(editor.document, same(before));
      editor.dispose();
    },
  );

  test('realtime binding uses IDs and invalid quality never displays zero', () {
    final doc = ScreenDocument.empty('A');
    final value = ScreenElement.create(
      'value',
      Offset.zero,
    ).update({'point_id': 'a', 'text': '温度 ', 'decimals': 2});
    final definitions = <String, Json>{
      'a': {'name': '同名', 'station': 'A', 'unit': '°C'},
      'b': {'name': '同名', 'station': 'B'},
    };
    ProcessValue read(String quality, {bool online = true}) =>
        processValue(value, doc, definitions, {
          'a': {'quality': quality, 'value': 23.456},
          'b': {'quality': 'good', 'value': 999},
        }, online);
    expect(read('good').text, '温度 23.46 °C');
    final custom = value.update({'decimals': 3, 'unit_override': '℃'});
    expect(
      processValue(custom, doc, definitions, {
        'a': {'quality': 'good', 'value': 23.456},
      }, true).text,
      '温度 23.456 ℃',
    );
    final template = ScreenDocument.fromJson(
      doc.copy(nodes: [custom]).toJson(),
    );
    expect(template.nodes.single.unitOverride, '℃');
    expect(template.nodes.single.decimals, 3);
    for (final quality in ['bad', 'stale', 'missing', 'uncertain']) {
      expect(read(quality).text, startsWith('—'));
      expect(read(quality).active, false);
    }
    expect(read('good', online: false).quality, 'offline');
    definitions['a']!['station'] = 'B';
    expect(read('good').quality, 'scope');
    definitions.remove('a');
    expect(read('good').quality, 'missing');
  });

  test('JSON import rejects invalid colors, clipping and unknown schema', () {
    final n = ScreenElement.create('text', const Offset(100, 100));
    final d = ScreenDocument.empty('A').copy(nodes: [n]);
    expect(
      () => ScreenDocument.fromJson({...d.toJson(), 'schema_version': 2}),
      throwsFormatException,
    );
    expect(
      () => d
          .copy(
            nodes: [
              n.update({'color': 'red'}),
            ],
          )
          .checkGeometry(),
      throwsFormatException,
    );
    expect(
      () => d
          .copy(
            nodes: [
              n.update({'x': 1590}),
            ],
          )
          .checkGeometry(),
      throwsFormatException,
    );
  });
  test(
    'each station instantiates independent graphics and bindings from one template',
    () {
      final variable = ScreenElement.create(
        'value',
        const Offset(100, 120),
      ).update({'point_id': 'a', 'decimals': 3, 'unit_override': 'MPa'});
      final template = ScreenDocument.empty('A').copy(nodes: [variable]);
      final sameStation = template.instantiate('A');
      final otherStation = template.instantiate('B');
      expect(sameStation.id, isNot(template.id));
      expect(otherStation.id, isNot(sameStation.id));
      expect(sameStation.nodes.single.pointID, '');
      expect(otherStation.nodes.single.pointID, '');
      expect(otherStation.nodes.single.decimals, 3);
      expect(otherStation.nodes.single.unitOverride, 'MPa');
      final editor = ProcessController(otherStation);
      editor.update(
        editor.document.nodes.single.update({'point_id': 'b', 'x': 300.0}),
      );
      expect(template.nodes.single.pointID, 'a');
      expect(template.nodes.single.x, 100);
      expect(sameStation.nodes.single.pointID, '');
      expect(editor.document.station, 'B');
      expect(editor.document.nodes.single.pointID, 'b');
      editor.dispose();
    },
  );
  test(
    'save completion tracks the submitted snapshot without clearing newer template edits',
    () {
      final editor = ProcessController(ScreenDocument.empty('A'));
      editor.add(ScreenElement.create('text', const Offset(100, 100)));
      final submitted = editor.document;
      editor.rename('较新的修改');
      editor.saved(1, snapshot: submitted);
      expect(editor.document.name, '较新的修改');
      expect(editor.document.revision, 1);
      expect(editor.dirty, true);
      editor.undo();
      expect(editor.dirty, false);
      editor.dispose();
    },
  );

  testWidgets(
    'pipe drawing, node placement and drag undo use the visible canvas',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final editor = ProcessController(ScreenDocument.empty('A'));
      final key = GlobalKey<ProcessCanvasState>();
      Future<void> canvas(String tool) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProcessCanvas(
                key: key,
                controller: editor,
                symbols: const {},
                definitions: const {},
                live: const {},
                online: true,
                tool: tool,
                onToolDone: () {},
                onSave: () {},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await canvas('rect');
      final origin = tester.getTopLeft(find.byKey(const Key('process-canvas')));
      Offset screen(Offset p) =>
          origin + key.currentState!.pan + p * key.currentState!.zoom;
      await tester.dragFrom(
        screen(const Offset(100, 100)),
        const Offset(100, 100) * key.currentState!.zoom,
      );
      await tester.pump();
      expect(editor.document.nodes.single.kind, 'rect');
      await canvas('pipe');
      await tester.tapAt(screen(const Offset(300, 150)));
      await tester.tapAt(screen(const Offset(500, 300)));
      expect(key.currentState!.pending, [
        const Offset(300, 150),
        const Offset(500, 150),
      ]);
      // A further click explicitly confirms the vertical segment.
      await tester.tapAt(screen(const Offset(500, 300)));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(editor.document.nodes.last.points.length, 3);
      await canvas('select');
      await tester.dragFrom(
        screen(const Offset(150, 150)),
        const Offset(50, 50) * key.currentState!.zoom,
      );
      await tester.pump();
      expect(editor.document.nodes.first.x, 150);
      editor.undo();
      await tester.pump();
      expect(editor.document.nodes.first.x, 100);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'property draft survives live refresh, save commits draft and conflict keeps edits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = ScreenApi();
      final session = ProcessSession('A')..loaded = true;
      Future<void> page() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
              session: session,
              station: 'A',
              definitions: const {},
              live: const {},
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await page();
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '画面名称',
      );
      await tester.enterText(field, '供热工艺');
      await page();
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '供热工艺');
      await tester.tap(find.byKey(const Key('process-save')));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['name'], '供热工艺');
      expect(session.controller.dirty, false);
      await tester.enterText(field, '未保存修订');
      api.conflict = true;
      await tester.tap(find.byKey(const Key('process-save')));
      await tester.pumpAndSettle();
      expect(session.controller.document.name, '未保存修订');
      expect(session.controller.dirty, true);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'development template survives switching to read-only process view and back',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = ProcessSession('A')..loaded = true;
      final node = ScreenElement.create(
        'value',
        const Offset(120, 150),
      ).update({'point_id': 'a', 'decimals': 3, 'unit_override': 'kPa'});
      session.controller.add(node);
      final api = ScreenApi();
      Future<void> page(bool development) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              key: ValueKey(development),
              api: api,
              session: session,
              station: 'A',
              definitions: const {
                'a': {'name': '压力', 'station': 'A'},
              },
              live: const {
                'a': {'quality': 'good', 'value': 12.34567},
              },
              online: true,
              canWrite: true,
              development: development,
            ),
          ),
        ),
      );
      await page(true);
      await tester.pumpAndSettle();
      expect(find.text('开发页 · 画面模板'), findsOneWidget);
      expect(find.byKey(const Key('process-tool-value')), findsOneWidget);
      await page(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('process-tool-value')), findsNothing);
      expect(find.byKey(const Key('process-save')), findsNothing);
      expect(find.text('12.346 kPa'), findsOneWidget);
      final before = session.controller.document;
      session.controller.move(const Offset(100, 100));
      expect(session.controller.document, same(before));
      await page(true);
      await tester.pumpAndSettle();
      expect(session.controller.document.nodes.single.x, 120);
      expect(session.controller.editing, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'one global development page targets stations independently; two screens per station stay distinct',
    (tester) async {
      final api = ScreenApi();
      api.rows.addAll([api.point('a', 'A'), api.point('b', 'B')]);
      for (final scope in ['A', 'B']) {
        for (final index in [1, 2]) {
          final id = '$scope$index';
          api.screens[id] = ScreenDocument(
            id: id,
            name: '$scope 图$index',
            station: scope,
            revision: 1,
            nodes: [
              ScreenElement.create('value', const Offset(100, 100)).update({
                'point_id': scope.toLowerCase(),
                'text': '$id ',
                'decimals': index,
              }),
            ],
          ).toJson();
        }
      }
      await tester.runAsync(() => processSymbols);
      await launch(tester, api, size: const Size(1600, 1000));
      await tester.tap(find.byKey(const Key('station-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-10')));
      await tester.pumpAndSettle();
      expect(find.byType(ProcessDevelopmentWorkspace), findsOneWidget);
      expect(find.byKey(const Key('nav-10')), findsOneWidget);
      expect(
        tester
            .widget<ProcessDevelopmentWorkspace>(
              find.byType(ProcessDevelopmentWorkspace),
            )
            .station,
        'A',
      );
      await tester.tap(find.byKey(const Key('process-screen-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A 图2').last);
      await tester.pumpAndSettle();
      expect(find.text('A2 21.50 °C'), findsOneWidget);
      // Choose B inside the global editor without changing the A station tab.
      await tester.tap(find.byKey(const Key('process-target-station')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();
      expect(find.text('B1 21.5 °C'), findsOneWidget);
      await tester.tap(find.byKey(const Key('process-screen-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B 图2').last);
      await tester.pumpAndSettle();
      expect(find.text('B2 21.50 °C'), findsOneWidget);
      await tester.tap(find.text('在该站查看'));
      await tester.pumpAndSettle();
      expect(find.byType(ProcessDevelopmentWorkspace), findsNothing);
      expect(find.byKey(const Key('process-save')), findsNothing);
      expect(find.text('B2 21.50 °C'), findsOneWidget);
      // The A tab kept its station page, never acquires its own development page.
      await tester.tap(find.byKey(const Key('station-A')));
      await tester.pumpAndSettle();
      expect(find.byType(ProcessDevelopmentWorkspace), findsNothing);
      await tester.tap(find.byKey(const Key('nav-9')));
      await tester.pumpAndSettle();
      expect(find.text('A2 21.50 °C'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-10')));
      await tester.pumpAndSettle();
      expect(find.text('B2 21.50 °C'), findsOneWidget);
      expect(
        tester
            .widget<ProcessDevelopmentWorkspace>(
              find.byType(ProcessDevelopmentWorkspace),
            )
            .station,
        'B',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
