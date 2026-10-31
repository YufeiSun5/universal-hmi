import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'process_test.dart' show ScreenApi;

Finder property(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

Offset scenePoint(WidgetTester tester, Offset point) {
  final state = tester.state<ProcessCanvasState>(find.byType(ProcessCanvas));
  return tester.getTopLeft(find.byKey(const Key('process-canvas'))) +
      state.pan +
      point * state.zoom;
}

Future<void> workspace(WidgetTester tester, ProcessSession session) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProcessWorkspace(
          api: ScreenApi(),
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
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('outer resize and pipe vertex handles win over marquee', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final node = ScreenElement.create(
      'rect',
      const Offset(100, 100),
    ).update({'width': 100.0, 'height': 100.0});
    final pipe = ScreenElement.create(
      'pipe',
      Offset.zero,
    ).withPoints([const Offset(400, 100), const Offset(500, 100)]);
    final session = ProcessSession('A')..loaded = true;
    final editor = session.controller
      ..snap = false
      ..smartGuides = false;
    editor.open(editor.document.copy(nodes: [node, pipe]));
    editor.select(node.id);
    await workspace(tester, session);
    var state = tester.state<ProcessCanvasState>(find.byType(ProcessCanvas));
    var gesture = await tester.startGesture(
      scenePoint(tester, Offset(200 + 5 / state.zoom, 150)),
    );
    await gesture.moveTo(scenePoint(tester, const Offset(230, 150)));
    await gesture.up();
    await tester.pump();
    expect(editor.document.nodes.first.width, greaterThan(120));
    editor.select(pipe.id);
    await tester.pump();
    state = tester.state<ProcessCanvasState>(find.byType(ProcessCanvas));
    gesture = await tester.startGesture(
      scenePoint(tester, Offset(500 + 8 / state.zoom, 100)),
    );
    await gesture.moveTo(scenePoint(tester, const Offset(550, 140)));
    await gesture.up();
    await tester.pump();
    expect(editor.document.nodes.last.points.last.dx, closeTo(550, .01));
    editor.selectMany({node.id, pipe.id});
    await tester.pump();
    expect(find.byKey(const Key('process-multi-count')), findsOneWidget);
    expect(find.text('已选择 2 个元素'), findsOneWidget);
    expect(find.byTooltip('复制副本'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
  testWidgets('canvas selection commits text to its original element once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = ScreenElement.create(
      'text',
      const Offset(100, 100),
    ).update({'text': '原文本'});
    final second = ScreenElement.create(
      'text',
      const Offset(500, 100),
    ).update({'text': '另一文本'});
    final session = ProcessSession('A')..loaded = true;
    final editor = session.controller;
    editor.open(editor.document.copy(nodes: [first, second]));
    editor.select(first.id);
    await workspace(tester, session);
    await tester.ensureVisible(property('文字内容'));
    await tester.enterText(property('文字内容'), '点击画布即提交');
    await tester.tapAt(scenePoint(tester, const Offset(530, 120)));
    await tester.pumpAndSettle();
    expect(editor.document.nodes.first.text, '点击画布即提交');
    expect(editor.document.nodes.last.text, '另一文本');
    expect(editor.selectedID, second.id);
    editor.undo();
    expect(editor.document.nodes.first.text, '原文本');
    expect(
      editor.canUndo,
      false,
      reason: 'one input must not create two undo entries',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'clicking empty canvas commits text and numeric draft before dragging',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final node = ScreenElement.create('text', const Offset(100, 100));
      final session = ProcessSession('A')..loaded = true;
      final editor = session.controller..snap = false;
      editor.open(editor.document.copy(nodes: [node]));
      editor.select(node.id);
      await workspace(tester, session);
      await tester.ensureVisible(property('文字内容'));
      await tester.enterText(property('文字内容'), '无需回车');
      await tester.tapAt(scenePoint(tester, const Offset(800, 400)));
      await tester.pumpAndSettle();
      expect(editor.document.nodes.single.text, '无需回车');
      await tester.tapAt(scenePoint(tester, const Offset(180, 120)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(property('宽'));
      await tester.enterText(property('宽'), '280');
      final gesture = await tester.startGesture(
        scenePoint(tester, const Offset(180, 120)),
      );
      await gesture.moveTo(scenePoint(tester, const Offset(220, 150)));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(editor.document.nodes.single.width, 280);
      expect(editor.document.nodes.single.x, closeTo(140, 0.01));
      expect(editor.document.nodes.single.text, '无需回车');
      editor.undo();
      expect(editor.document.nodes.single.width, 280);
      expect(editor.document.nodes.single.x, 100);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  for (final kind in ['rect', 'ellipse', 'text', 'value']) {
    testWidgets('$kind is sized by primary-button drag in either direction', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final editor = ProcessController(ScreenDocument.empty('A'))..snap = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessCanvas(
              controller: editor,
              symbols: const {},
              definitions: const {},
              live: const {},
              online: true,
              tool: kind,
              onToolDone: () {},
              onSave: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        scenePoint(tester, const Offset(440, 320)),
        kind: PointerDeviceKind.mouse,
      );
      expect(
        editor.document.nodes,
        isEmpty,
        reason: 'pressing alone must not place a fixed-size shape',
      );
      await gesture.moveTo(scenePoint(tester, const Offset(100, 120)));
      await tester.pump();
      expect(
        editor.document.nodes,
        isEmpty,
        reason: 'preview is not a committed element',
      );
      await gesture.up();
      await tester.pump();
      expect(editor.document.nodes.single.kind, kind);
      final rect = editor.document.nodes.single.rect;
      expect(rect.left, closeTo(100, 0.001));
      expect(rect.top, closeTo(120, 0.001));
      expect(rect.width, closeTo(340, 0.001));
      expect(rect.height, closeTo(200, 0.001));
      editor.document.checkGeometry();
      editor.undo();
      expect(editor.document.nodes, isEmpty);
      editor.redo();
      expect(editor.document.nodes.single.width, closeTo(340, 0.001));
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    });
  }

  testWidgets('cancelled and click-only rectangle creation leave no element', (
    tester,
  ) async {
    final editor = ProcessController(ScreenDocument.empty('A'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessCanvas(
            controller: editor,
            symbols: const {},
            definitions: const {},
            live: const {},
            online: true,
            tool: 'rect',
            onToolDone: () {},
            onSave: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tapAt(scenePoint(tester, const Offset(100, 100)));
    expect(editor.document.nodes, isEmpty);
    final gesture = await tester.startGesture(
      scenePoint(tester, const Offset(100, 100)),
    );
    await gesture.moveTo(scenePoint(tester, const Offset(300, 300)));
    await gesture.cancel();
    await tester.pump();
    expect(editor.document.nodes, isEmpty);
    expect(editor.canUndo, false);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  final resizeCases = <(String, Offset, Offset, Rect)>[
    (
      'left minimum',
      const Offset(200, 280),
      const Offset(600, 280),
      const Rect.fromLTWH(432, 200, 8, 160),
    ),
    (
      'top minimum',
      const Offset(320, 200),
      const Offset(320, 600),
      const Rect.fromLTWH(200, 352, 240, 8),
    ),
    (
      'right canvas boundary',
      const Offset(440, 280),
      const Offset(2000, 280),
      const Rect.fromLTWH(200, 200, 1400, 160),
    ),
    (
      'bottom canvas boundary',
      const Offset(320, 360),
      const Offset(320, 1200),
      const Rect.fromLTWH(200, 200, 240, 700),
    ),
    (
      'left',
      const Offset(200, 280),
      const Offset(150, 280),
      const Rect.fromLTWH(150, 200, 290, 160),
    ),
    (
      'right',
      const Offset(440, 280),
      const Offset(490, 280),
      const Rect.fromLTWH(200, 200, 290, 160),
    ),
    (
      'top',
      const Offset(320, 200),
      const Offset(320, 150),
      const Rect.fromLTWH(200, 150, 240, 210),
    ),
    (
      'bottom',
      const Offset(320, 360),
      const Offset(320, 410),
      const Rect.fromLTWH(200, 200, 240, 210),
    ),
    (
      'top-left',
      const Offset(200, 200),
      const Offset(150, 150),
      const Rect.fromLTWH(150, 150, 290, 210),
    ),
    (
      'top-right',
      const Offset(440, 200),
      const Offset(490, 150),
      const Rect.fromLTWH(200, 150, 290, 210),
    ),
    (
      'bottom-left',
      const Offset(200, 360),
      const Offset(150, 410),
      const Rect.fromLTWH(150, 200, 290, 210),
    ),
    (
      'bottom-right',
      const Offset(440, 360),
      const Offset(490, 410),
      const Rect.fromLTWH(200, 200, 290, 210),
    ),
  ];
  for (final (name, start, end, expected) in resizeCases) {
    testWidgets(
      '$name edge resize anchors the opposite edge and undoes in one step',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final node = ScreenElement.create(
          'rect',
          const Offset(200, 200),
        ).update({'width': 240.0, 'height': 160.0});
        final editor = ProcessController(
          ScreenDocument.empty('A').copy(nodes: [node]),
        )..snap = false;
        editor.select(node.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProcessCanvas(
                controller: editor,
                symbols: const {},
                definitions: const {},
                live: const {},
                online: true,
                tool: 'select',
                onToolDone: () {},
                onSave: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        final gesture = await tester.startGesture(
          scenePoint(tester, start),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(scenePoint(tester, end));
        await gesture.up();
        await tester.pump();
        final actual = editor.document.nodes.single.rect;
        expect(actual.left, closeTo(expected.left, 0.01));
        expect(actual.top, closeTo(expected.top, 0.01));
        expect(actual.width, closeTo(expected.width, 0.01));
        expect(actual.height, closeTo(expected.height, 0.01));
        editor.document.checkGeometry();
        editor.undo();
        expect(editor.document.nodes.single.rect, node.rect);
        expect(editor.canUndo, false);
        await tester.pumpWidget(const SizedBox());
        editor.dispose();
      },
    );
  }
}
