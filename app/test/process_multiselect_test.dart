import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';

void main() {
  test(
    'copy and move preserve internal pipe connections and detach external ones',
    () {
      final root = ScreenElement.create(
        'pipe',
        Offset.zero,
      ).withPoints([const Offset(100, 100), const Offset(500, 100)]);
      final branch = ScreenElement.create('pipe', Offset.zero).withPoints(
        [const Offset(300, 100), const Offset(300, 300)],
        changes: {'start_node': root.id, 'start_port': 'path:0.5'},
      );
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [root, branch]),
      )..snap = false;
      editor.selectMany({root.id, branch.id});
      editor.copy();
      editor.paste();
      final copiedRoot = editor.document.nodes[2];
      final copiedBranch = editor.document.nodes[3];
      expect(copiedBranch.startNode, copiedRoot.id);
      expect(
        editor.document.pipePoints(copiedBranch).first,
        const Offset(320, 120),
      );
      editor.beginGesture();
      editor.gestureMoveSelection(const Offset(30, 40));
      editor.endGesture();
      expect(
        editor.document.pipePoints(editor.document.nodes[3]).first,
        const Offset(350, 160),
      );
      editor.undo();
      expect(
        editor.document.pipePoints(editor.document.nodes[3]).first,
        const Offset(320, 120),
      );
      editor.select(branch.id);
      editor.copy();
      editor.paste();
      expect(editor.document.nodes.last.startNode, isEmpty);
      editor.dispose();
    },
  );
  testWidgets(
    'marquee selects at transformed scale and batch edits undo once',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final a = ScreenElement.create('rect', const Offset(100, 100));
      final b = ScreenElement.create('rect', const Offset(350, 100));
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [a, b]),
      )..snap = false;
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
      final state = tester.state<ProcessCanvasState>(
        find.byType(ProcessCanvas),
      );
      Offset point(Offset p) =>
          tester.getTopLeft(find.byKey(const Key('process-canvas'))) +
          state.pan +
          p * state.zoom;
      final gesture = await tester.startGesture(point(const Offset(50, 50)));
      await gesture.moveTo(point(const Offset(600, 300)));
      await gesture.up();
      await tester.pump();
      expect(editor.selectedIDs, {a.id, b.id});
      final drag = await tester.startGesture(point(const Offset(140, 130)));
      await drag.moveTo(point(const Offset(180, 160)));
      await drag.up();
      await tester.pump();
      expect(editor.document.nodes.first.x, closeTo(140, .01));
      expect(editor.document.nodes.last.x, closeTo(390, .01));
      editor.undo();
      expect(editor.document.nodes.first.x, 100);
      expect(editor.document.nodes.last.x, 350);
      expect(editor.canUndo, false);
      editor.redo();
      editor.selectMany({a.id, b.id});
      editor.copy();
      editor.paste();
      expect(editor.document.nodes.length, 4);
      editor.undo();
      expect(editor.document.nodes.length, 2);
      editor.selectMany({a.id, b.id});
      editor.removeSelected();
      expect(editor.document.nodes, isEmpty);
      editor.undo();
      expect(editor.document.nodes.length, 2);
      await tester.tapAt(point(const Offset(800, 500)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(editor.selectedIDs, {a.id, b.id});
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );
}
