import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/diagram.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/preview.dart';
import 'package:universal_hmi/features/process/templates.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class DelayedScreenApi extends ScreenApi {
  final gate = Completer<void>();
  int lists = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/screens') {
      lists++;
      await gate.future;
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a dialog receives rebuilt workspace data without notifying during build',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(ProcessSymbol.load);
      final session = ProcessSession('A')..loaded = true, api = ScreenApi();
      session.controller.add(
        ScreenElement.create(
          'value',
          const Offset(30, 30),
        ).update({'point_id': 'p', 'decimals': 1, 'unit_override': 'MPa'}),
      );
      Future<void> host(double value) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
              session: session,
              station: 'A',
              definitions: const {
                'p': {'station': 'A', 'name': '压力'},
              },
              live: {
                'p': {'quality': 'good', 'value': value},
              },
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await host(1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('process-preview-embedded')));
      await tester.pumpAndSettle();
      expect(find.byType(ProcessEmbeddedPreview), findsOneWidget);
      await host(2);
      await tester.pumpAndSettle();
      expect(find.text('2.0 MPa'), findsWidgets);
      expect(find.text('1.0 MPa'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'embedded preview follows host snapshots and preserves zoom across value changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final doc = ScreenDocument.empty('A').copy(
        nodes: [
          ScreenElement.create('value', const Offset(20, 20)).update({
            'width': 50.0,
            'height': 24.0,
            'point_id': 'p',
            'label': '压力',
            'decimals': 3,
            'unit_override': 'MPa',
          }),
        ],
      );
      const definitions = <String, Json>{
        'p': {'station': 'A', 'name': '压力', 'data_type': 'FLOAT'},
      };
      final readings = ValueNotifier(
        const ProcessReadings(definitions, {
          'p': {'quality': 'good', 'value': .321},
        }, true),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessEmbeddedPreview(
              document: doc,
              symbols: const {},
              readings: readings,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0.321 MPa'), findsOneWidget);
      await tester.tap(find.byKey(const Key('diagram-zoom-in')));
      await tester.pump();
      final zoomed = tester.getRect(find.byKey(const Key('diagram-scene')));
      readings.value = const ProcessReadings(definitions, {
        'p': {'quality': 'good', 'value': .654},
      }, true);
      await tester.pump();
      expect(find.text('0.654 MPa'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('diagram-scene'))), zoomed);
      readings.value = const ProcessReadings(definitions, {}, false);
      await tester.pump();
      expect(find.text('— 离线'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      readings.dispose();
    },
  );
  test(
    'reference is an editable, unbound blueprint with labels, units and separate station copies',
    () async {
      final a = await ProcessTemplates.heatingStation('A'),
          b = await ProcessTemplates.heatingStation('B');
      expect(a.nodes.length, 120);
      expect(a.nodes.where((n) => n.symbol == 'example_plate_hx').length, 3);
      expect(a.nodes.where((n) => n.symbol == 'example_pump').length, 5);
      expect(
        a.nodes
            .where((n) => n.kind == 'value')
            .every(
              (n) =>
                  n.pointID.isEmpty &&
                  n.label.isNotEmpty &&
                  n.unitOverride.isNotEmpty,
            ),
        true,
      );
      expect(a.id, isNot(b.id));
      expect(a.station, 'A');
      expect(b.station, 'B');
      a.checkGeometry();
      final roundTrip = ScreenDocument.fromJson(
        jsonDecode(jsonEncode(a.toJson())) as Json,
      );
      expect(roundTrip.toJson(), a.toJson());
      final hx = a.nodes.firstWhere((n) => n.symbol == 'example_plate_hx');
      expect(a.ports(hx).length, 4);
      expect(
        a.port(hx.id, 'left_top').dy,
        85.421875,
        reason: 'the SVG nozzle center is y=32.5 in its 160-unit viewport',
      );
    },
  );
  test(
    'shared loading deduplicates requests and preserves an in-flight draft',
    () async {
      final api = DelayedScreenApi(), session = ProcessSession('A');
      api.screens['saved'] = ScreenDocument.empty(
        'A',
      ).copy(id: 'saved', revision: 1).toJson();
      final first = session.ensureLoaded(api),
          second = session.ensureLoaded(api);
      session.controller.add(
        ScreenElement.create('text', const Offset(30, 30)),
      );
      final draft = session.controller.document;
      api.gate.complete();
      await Future.wait([first, second]);
      expect(api.lists, 1);
      expect(session.loaded, true);
      expect(session.controller.document, same(draft));
      session.dispose();
    },
  );
  testWidgets(
    'whole native scene fits four embedded sizes, resizes after zoom, and exposes readable units',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final doc = (await tester.runAsync(
        () => ProcessTemplates.heatingStation('A'),
      ))!;
      final symbols = {
        for (final s in (await tester.runAsync(ProcessSymbol.load))!) s.id: s,
      };
      Future<void> host(Size size) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: ProcessDiagram(
                    key: const ValueKey('same-component'),
                    document: doc,
                    symbols: symbols,
                    definitions: const {},
                    live: const {},
                    online: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      void containsScene() {
        final viewport = tester.getRect(
          find.byKey(const Key('diagram-viewport')),
        );
        final scene = tester.getRect(find.byKey(const Key('diagram-scene')));
        expect(scene.left, greaterThanOrEqualTo(viewport.left));
        expect(scene.top, greaterThanOrEqualTo(viewport.top));
        expect(scene.right, lessThanOrEqualTo(viewport.right));
        expect(scene.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(tester.takeException(), isNull);
      }

      for (final size in [
        const Size(960, 480),
        const Size(640, 360),
        const Size(360, 300),
        const Size(640, 220),
      ]) {
        await host(size);
        containsScene();
      }
      await tester.tap(find.byKey(const Key('diagram-zoom-in')));
      await tester.pump();
      await host(const Size(360, 300));
      containsScene();
      await tester.tap(find.byKey(const Key('diagram-variables')));
      await tester.pumpAndSettle();
      expect(find.text('一次供水温度'), findsOneWidget);
      expect(find.textContaining('未绑定 °C'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'explicit new template creates reference and persists labels without affecting another station',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = ScreenApi(),
          a = ProcessSession('A')..loaded = true,
          b = ProcessSession('B')..loaded = true;
      final originalB = b.controller.document;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
              session: a,
              station: 'A',
              definitions: const {},
              live: const {},
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('process-new-template')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('内置模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-builtin-heating-basic')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new-screen-name')),
        'A 工艺示例',
      );
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      expect(a.controller.document.nodes.length, 120);
      expect(a.controller.dirty, false);
      await tester.tap(find.byKey(const Key('process-save')));
      await tester.pumpAndSettle();
      expect(a.controller.dirty, false);
      final saved = ScreenDocument.fromJson(api.savedScreen!);
      expect(
        saved.nodes
            .where((n) => n.kind == 'value')
            .every((n) => n.label.isNotEmpty),
        true,
      );
      expect(b.controller.document, same(originalB));
      await tester.pumpWidget(const SizedBox());
      a.dispose();
      b.dispose();
    },
  );
}
