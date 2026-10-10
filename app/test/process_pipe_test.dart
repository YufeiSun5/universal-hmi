import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/alignment.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/pipe_drawing.dart';
import 'package:universal_hmi/features/process/pipe_flow.dart';
import 'package:universal_hmi/features/process/pipe_geometry.dart' as geometry;
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_interaction_test.dart' show workspace, scenePoint;

Json rule(String match, List<Json> conditions) => {
  'match': match,
  'conditions': conditions,
};
Json comparison(String id, String operator, double value) => {
  'slot': '测试变量',
  'point_id': id,
  'operator': operator,
  'value': value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('smart guides snap centers and pipe axes with screen tolerance', () {
    final device = ScreenElement.create(
      'symbol',
      const Offset(100, 100),
    ).update({'width': 80.0, 'height': 80.0});
    final pipe = ScreenElement.create(
      'pipe',
      Offset.zero,
    ).withPoints([const Offset(300, 300), const Offset(600, 300)]);
    final doc = ScreenDocument.empty('A').copy(nodes: [device, pipe]);
    final snap = alignToScene(doc, [const Offset(144, 297)], 6);
    expect(snap.delta, const Offset(-4, 3));
    expect(snap.guides.length, 2);
    expect(alignToScene(doc, [const Offset(144, 297)], 3).guides.length, 1);
    expect(
      alignToScene(
        doc,
        [const Offset(144, 297)],
        6,
        exclude: device.id,
      ).delta.dx,
      0,
    );
    expect(
      alignToScene(doc, [const Offset(144, 297)], 6, allowY: false).delta.dy,
      0,
    );
  });
  testWidgets(
    'drag centers align, Shift constrains direction and undo restores',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixed = ScreenElement.create(
        'rect',
        const Offset(300, 100),
      ).update({'width': 80.0, 'height': 80.0});
      final moving = ScreenElement.create(
        'rect',
        const Offset(100, 300),
      ).update({'width': 80.0, 'height': 80.0});
      final session = ProcessSession('A')..loaded = true;
      final editor = session.controller..snap = false;
      editor.open(editor.document.copy(nodes: [fixed, moving]));
      await workspace(tester, session);
      final drag = await tester.startGesture(
        scenePoint(tester, moving.rect.center),
      );
      await drag.moveTo(scenePoint(tester, const Offset(336, 240)));
      await tester.pump();
      expect(editor.selected!.rect.center.dx, 340);
      final state = tester.state<ProcessCanvasState>(
        find.byType(ProcessCanvas),
      );
      expect(state.guides.any((g) => g.vertical && g.position == 340), true);
      await drag.up();
      editor.undo();
      expect(editor.document.nodes.last.rect, moving.rect);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final constrained = await tester.startGesture(
        scenePoint(tester, moving.rect.center),
      );
      await constrained.moveTo(
        scenePoint(tester, moving.rect.center + const Offset(100, 20)),
      );
      await constrained.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(editor.selected!.y, moving.y);
      expect(editor.selected!.x, 200);
      expect(state.guides, isEmpty);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  test('reverse arrows render at the opposite end and survive JSON', () async {
    Future<int> whiteAt(bool reverse, int x) async {
      final recorder = ui.PictureRecorder();
      FlowPipePainter(
        [const Offset(10, 60), const Offset(110, 60)],
        Colors.blue,
        20,
        true,
        style: 'cylinder',
        reverse: reverse,
      ).paint(Canvas(recorder), const Size(120, 120));
      final picture = recorder.endRecording();
      final image = await picture.toImage(120, 120);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final red = bytes.getUint8((60 * 120 + x) * 4);
      image.dispose();
      picture.dispose();
      return red;
    }

    expect(await whiteAt(false, 106), greaterThan(240));
    expect(await whiteAt(true, 14), greaterThan(240));
    expect(await whiteAt(false, 14), lessThan(240));
    expect(await whiteAt(true, 106), lessThan(240));
    final node = ScreenElement.create('pipe', Offset.zero).withPoints(
      [const Offset(10, 60), const Offset(110, 60)],
      changes: {'arrow_reverse': true},
    );
    expect(
      ScreenDocument.fromJson(
        ScreenDocument.empty('A').copy(nodes: [node]).toJson(),
      ).nodes.single.arrowReverse,
      true,
    );
  });

  test(
    'horizontal drawing ignores mouse drift; turns require another click',
    () {
      final draft = PipeDraft()..add([const Offset(100, 100)]);
      for (var i = 0; i < 100; i++) {
        final next = draft.preview(
          Offset(200 + i.toDouble(), 110 + i % 5),
          PipeDrawingMode.orthogonal,
          15,
          const Size(1600, 900),
        );
        expect(next[1].dy, 100);
        expect(next.length, 2);
        expect(draft.points.length, 1);
      }
      draft.add(
        draft.preview(
          const Offset(300, 200),
          PipeDrawingMode.orthogonal,
          15,
          const Size(1600, 900),
        ),
      );
      expect(draft.points, [const Offset(100, 100), const Offset(300, 100)]);
      draft.undo();
      expect(draft.points, [const Offset(100, 100)]);
      draft.redo();
      expect(draft.points.last, const Offset(300, 100));
      draft.add(
        draft.preview(
          const Offset(306, 200),
          PipeDrawingMode.orthogonal,
          15,
          const Size(1600, 900),
        ),
      );
      expect(draft.points.last, const Offset(300, 200));
      final connected = draft.preview(
        const Offset(400, 250),
        PipeDrawingMode.orthogonal,
        15,
        const Size(1600, 900),
        connected: true,
      );
      expect(connected.last, const Offset(400, 250));
      expect(connected[connected.length - 2], const Offset(300, 250));
      draft.undo();
      draft.undo();
      draft.undo();
      expect(draft.points, isEmpty);
    },
  );
  test('free angles, 15 degree increments and boundary truncation', () {
    final draft = PipeDraft()..add([const Offset(1500, 850)]);
    final target = const Offset(1600, 900);
    final free = draft.preview(
      target,
      PipeDrawingMode.free,
      15,
      const Size(1600, 900),
    );
    expect(free, [const Offset(1500, 850), target]);
    final snapped = draft.preview(
      target,
      PipeDrawingMode.angle,
      15,
      const Size(1600, 900),
    );
    final delta = snapped.last - snapped.first;
    expect(delta.direction * 180 / math.pi, closeTo(30, 1e-8));
    expect(snapped.last.dy, closeTo(900, 1e-8));
    expect(snapped.last.dx, lessThan(1600));
    final connected = draft.preview(
      target,
      PipeDrawingMode.angle,
      15,
      const Size(1600, 900),
      connected: true,
    );
    expect(connected.last, target);
  });
  test(
    'pipe endpoint and branch anchors follow movement, persist and detach on deletion',
    () {
      final root = ScreenElement.create(
        'pipe',
        Offset.zero,
      ).withPoints([const Offset(100, 100), const Offset(500, 100)]);
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [root]),
      );
      final endpoint = editor.connection(const Offset(503, 103), 10)!;
      expect(endpoint.$3, const Offset(500, 100));
      final joint = editor.connection(const Offset(300, 103), 10)!;
      expect(joint.$3, const Offset(300, 100));
      editor.addPipe([joint.$3, const Offset(300, 300)], start: joint);
      final branch = editor.selected!;
      editor.update(root.moved(const Offset(20, 30)));
      expect(editor.document.pipePoints(branch).first, const Offset(320, 130));
      final loaded = ScreenDocument.fromJson(editor.document.toJson());
      expect(
        loaded.pipePoints(loaded.nodes.last).first,
        const Offset(320, 130),
      );
      editor.select(root.id);
      editor.removeSelected();
      expect(editor.document.nodes.single.startNode, '');
      expect(editor.document.nodes.single.points.first, const Offset(320, 130));
      editor.undo();
      expect(editor.document.nodes.last.startNode, root.id);
      final a = root.update({'start_node': branch.id, 'start_port': 'path:0'});
      expect(
        () => ScreenDocument.fromJson(loaded.copy(nodes: [a, branch]).toJson()),
        throwsFormatException,
      );
      editor.dispose();
    },
  );
  test(
    'rounded bends share geometry with junctions and whole pipe arrow count',
    () {
      final vertices = [
        const Offset(100, 100),
        const Offset(500, 100),
        const Offset(500, 500),
      ];
      final route = geometry.pipeRoute(vertices, true, 40);
      expect(route.points.first, vertices.first);
      expect(route.points.last, vertices.last);
      expect(route.bends.single.start, const Offset(460, 100));
      expect(route.bends.single.end, const Offset(500, 140));
      expect(arrowDistances(route.points, 'segments', 80, 3, 0).length, 3);
      final bendPoint = route.points[route.points.length ~/ 2];
      expect((bendPoint - const Offset(460, 140)).distance, closeTo(40, 1e-7));
      final root = ScreenElement.create('pipe', Offset.zero).withPoints(
        vertices,
        changes: {'pipe_bend_radius': 40.0, 'pipe_elbows': true},
      );
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [root]),
      );
      final connection = editor.connection(bendPoint, .1)!;
      expect(connection.$3.dx, closeTo(bendPoint.dx, 1e-7));
      editor.addPipe(
        [connection.$3, connection.$3 + const Offset(100, 100)],
        start: connection,
        orthogonal: false,
      );
      expect(
        (editor.document.pipePoints(editor.selected!).first - bendPoint)
            .distance,
        lessThan(1e-7),
      );
      final restored = ScreenDocument.fromJson(
        editor.document.toJson(),
      ).nodes.first;
      expect(restored.pipeRounded, true);
      expect(restored.pipeElbows, true);
      expect(restored.points, vertices);
      final short = geometry.pipeRoute(
        [Offset.zero, const Offset(10, 0), const Offset(10, 10)],
        true,
        128,
      );
      expect(short.bends.single.start.dx, closeTo(5, 1e-7));
      expect(short.bends.single.end.dy, closeTo(5, 1e-7));
      expect(geometry.pipeRoute(vertices, false, 40).points, vertices);
      editor.dispose();
    },
  );
  test(
    'arrow interval, whole count, legacy mode and animation keep limits',
    () {
      final points = [
        const Offset(0, 0),
        const Offset(300, 0),
        const Offset(300, 200),
      ];
      expect(arrowDistances(points, 'spacing', 100, 3, 0), [
        50,
        150,
        250,
        350,
        450,
      ]);
      expect(arrowDistances(points, 'count', 100, 4, 0).length, 4);
      expect(arrowDistances(points, 'count', 100, 4, 63).length, 4);
      expect(arrowDistances(points, 'segments', 100, 3, 0).length, 3);
      expect(
        arrowDistances(points, 'count', 100, 4, 63),
        isNot(arrowDistances(points, 'count', 100, 4, 0)),
      );
      final many = List.generate(256, (i) => Offset(i * 100.0, 0));
      expect(arrowDistances(many, 'spacing', 12, 64, 1).length, 512);
    },
  );
  test(
    'cylinder shading has a transverse highlight and preserves flat legacy pipes',
    () async {
      Future<List<int>> pixelColors(
        String style,
        List<Offset> points,
        List<Offset> samples,
      ) async {
        final recorder = ui.PictureRecorder();
        FlowPipePainter(
          points,
          Colors.blue,
          20,
          false,
          style: style,
        ).paint(Canvas(recorder), const Size(120, 120));
        final picture = recorder.endRecording();
        final image = await picture.toImage(120, 120);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final values = [
          for (final p in samples)
            bytes.getUint8((p.dy.toInt() * 120 + p.dx.toInt()) * 4 + 1),
        ];
        image.dispose();
        picture.dispose();
        return values;
      }

      final horizontal = [const Offset(10, 60), const Offset(110, 60)];
      final vertical = [const Offset(60, 10), const Offset(60, 110)];
      final samples = [const Offset(60, 57), const Offset(60, 67)];
      final cylinder = await pixelColors('cylinder', horizontal, samples);
      expect(cylinder.first, greaterThan(cylinder.last + 50));
      final upright = await pixelColors('cylinder', vertical, [
        const Offset(57, 60),
        const Offset(67, 60),
      ]);
      expect(upright.first, greaterThan(upright.last + 50));
      final flat = await pixelColors('flat', horizontal, samples);
      expect(flat.first, flat.last);
      final legacy = Map<String, dynamic>.of(
        ScreenElement.create('pipe', Offset.zero).data,
      )..remove('pipe_style');
      expect(ScreenElement(legacy).pipeStyle, 'flat');
    },
  );
  test(
    'multiple variable display conditions are fail closed on any invalid input',
    () {
      final definitions = <String, Json>{
        'a': {'station': 'A'},
        'b': {'station': 'A'},
      };
      final live = <String, Json>{
        'a': {'quality': 'good', 'value': 20},
        'b': {'quality': 'good', 'value': true},
      };
      final all = rule('all', [
        comparison('a', '>', 10),
        comparison('b', '==', 1),
      ]);
      expect(evaluateArrowRule(all, 'A', definitions, live, true), true);
      expect(evaluateArrowRule(all, 'B', definitions, live, true), isNull);
      live['b'] = {'quality': 'stale', 'value': true};
      expect(
        evaluateArrowRule(
          {...all, 'match': 'any'},
          'A',
          definitions,
          live,
          true,
        ),
        isNull,
      );
      live['b'] = {'quality': 'good', 'value': false};
      expect(evaluateArrowRule(all, 'A', definitions, live, true), false);
      expect(
        evaluateArrowRule(
          {...all, 'match': 'any'},
          'A',
          definitions,
          live,
          true,
        ),
        true,
      );
      expect(evaluateArrowRule(all, 'A', definitions, live, false), isNull);
      expect(
        evaluateArrowRule(
          rule('all', [comparison('', '>', 0)]),
          'A',
          definitions,
          live,
          true,
        ),
        isNull,
      );
    },
  );
  test(
    'template export and every instantiation remove actual bindings but retain slots and style',
    () {
      final pipe = ScreenElement.create('pipe', Offset.zero).withPoints(
        [const Offset(10, 20), const Offset(300, 20)],
        changes: {
          'point_id': 'a',
          'arrow_mode': 'spacing',
          'arrow_spacing': 100.0,
          'arrow_animate': true,
          'arrow_visible_rule': rule('all', [comparison('b', '>', 10)]),
          'arrow_motion_rule': rule('any', [comparison('c', '<', 20)]),
        },
      );
      final document = ScreenDocument.empty('A').copy(nodes: [pipe]);
      for (final copy in [
        document.toTemplate(),
        document.instantiate('A'),
        document.instantiate('B'),
      ]) {
        final n = ScreenDocument.fromJson(copy.toJson()).nodes.single;
        expect(n.pointID, '');
        expect(
          objects(n.arrowVisibleRule!['conditions']).single['point_id'],
          '',
        );
        expect(
          objects(n.arrowMotionRule!['conditions']).single['point_id'],
          '',
        );
        expect(n.pipeStyle, 'cylinder');
        expect(n.arrowSpacing, 100);
        expect(n.arrowAnimate, true);
        expect(
          objects(n.arrowVisibleRule!['conditions']).single['slot'],
          '测试变量',
        );
      }
      expect(document.nodes.single.pointID, 'a');
      expect(
        objects(
          document.nodes.single.arrowVisibleRule!['conditions'],
        ).single['point_id'],
        'b',
      );
    },
  );
  testWidgets(
    'drawing undo button and keyboard affect draft, hover and leaving canvas create no folds',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = ProcessSession('A')..loaded = true;
      final node = ScreenElement.create('text', const Offset(30, 30));
      session.controller.add(node);
      await workspace(tester, session);
      await tester.tap(find.byKey(const Key('process-tool-pipe')));
      await tester.pumpAndSettle();
      final state = tester.state<ProcessCanvasState>(
        find.byType(ProcessCanvas),
      );
      await tester.tapAt(scenePoint(tester, const Offset(300, 300)));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: scenePoint(tester, const Offset(500, 450)),
      );
      await mouse.moveTo(scenePoint(tester, const Offset(500, 450)));
      await tester.pump();
      expect(state.pending.length, 1);
      expect(state.pipePreview.length, 2);
      await tester.tapAt(scenePoint(tester, const Offset(500, 450)));
      await tester.pumpAndSettle();
      expect(state.hover, isNull);
      expect(state.pending.length, 2);
      expect(state.pipePreview, state.pending);
      await tester.tap(find.byKey(const Key('pipe-undo-step')));
      await tester.pumpAndSettle();
      expect(state.pending.length, 1);
      expect(session.controller.document.nodes.single.id, node.id);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(state.pending, isEmpty);
      expect(session.controller.document.nodes.single.id, node.id);
      expect(session.controller.canUndo, true);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'flow animation starts and stops without creating document changes',
    (tester) async {
      final node = ScreenElement.create('pipe', Offset.zero).withPoints(
        [const Offset(10, 50), const Offset(400, 50)],
        changes: {
          'arrow_animate': true,
          'arrow_mode': 'count',
          'arrow_count': 4,
        },
      );
      Future<void> draw(bool moving) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 500,
            height: 100,
            child: PipeFlow(
              points: node.points,
              node: node,
              color: Colors.blue,
              state: PipeFlowState(true, moving, false),
            ),
          ),
        ),
      );
      await draw(true);
      await tester.pump(const Duration(milliseconds: 100));
      FlowPipePainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<FlowPipePainter>()
          .single;
      final initial = painter().phase;
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter().phase, greaterThan(initial));
      await draw(false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter().phase, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
