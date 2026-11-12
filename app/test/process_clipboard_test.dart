import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/session.dart';

void main() {
  test(
    'workspace clipboard survives switching and closing source, keeps bindings and assets without replacing target images',
    () {
      final clipboard = ProcessClipboard();
      final source = ProcessSession('A', clipboard: clipboard);
      final target = ProcessSession('B', clipboard: clipboard);
      final existing = EmbeddedImage('existing.png', 'image/png', 'b2xk');
      final copied = EmbeddedImage('copied.png', 'image/png', 'bmV3');
      final image = ScreenElement.create(
        'image',
        const Offset(600, 400),
        image: 'same-key',
      );
      final value = ScreenElement.create(
        'value',
        const Offset(710, 400),
      ).update({'point_id': 'stable-point-A'});
      source.controller.open(
        source.controller.document.copy(
          nodes: [image, value],
          assets: {'same-key': copied},
        ),
      );
      source.controller.selectAll();
      source.controller.copy();
      source.dispose();
      final originalImage = ScreenElement.create(
        'image',
        const Offset(10, 10),
        image: 'same-key',
      );
      target.controller.open(
        target.controller.document.copy(
          width: 400,
          height: 300,
          nodes: [originalImage],
          assets: {'same-key': existing},
        ),
      );
      final before = target.controller.document;
      target.controller.paste();
      final doc = target.controller.document;
      expect(doc.assets['same-key'], same(existing));
      expect(doc.nodes[1].image, isNot('same-key'));
      expect(doc.assets[doc.nodes[1].image], same(copied));
      expect(doc.nodes[2].pointID, 'stable-point-A');
      expect(doc.nodes[2].x - doc.nodes[1].x, 110);
      expect(doc.nodes[1].id, isNot(image.id));
      doc.checkGeometry();
      target.controller.undo();
      expect(target.controller.document.toJson(), before.toJson());
      target.controller.redo();
      expect(target.controller.document.toJson(), doc.toJson());
      final separate = ProcessSession('A');
      expect(separate.controller.canPaste, isFalse);
      separate.dispose();
      target.dispose();
    },
  );

  test(
    'cross-screen pipes rebind copied nodes and detach unselected source nodes',
    () {
      final clipboard = ProcessClipboard();
      final root = ScreenElement.create(
        'pipe',
        Offset.zero,
      ).withPoints([const Offset(100, 100), const Offset(400, 100)]);
      final branch = ScreenElement.create('pipe', Offset.zero).withPoints(
        [const Offset(250, 100), const Offset(250, 300)],
        changes: {'start_node': root.id, 'start_port': 'path:0.5'},
      );
      final source = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [root, branch]),
        clipboard: clipboard,
      );
      final target = ProcessController(
        ScreenDocument.empty('B'),
        clipboard: clipboard,
      );
      source.selectAll();
      source.copy();
      target.paste();
      expect(target.document.nodes[1].startNode, target.document.nodes[0].id);
      target.document.checkGeometry();
      source.select(branch.id);
      source.copy();
      target.paste();
      expect(target.document.nodes.last.startNode, '');
      target.document.checkGeometry();
      target.editing = false;
      final before = target.document;
      target.paste();
      expect(target.document, same(before));
      source.dispose();
      target.dispose();
    },
  );

  test(
    'oversized cross-screen paste is atomic and opening another screen keeps clipboard',
    () {
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(
          nodes: [
            ScreenElement.create('rect', Offset.zero).update({'width': 600.0}),
          ],
        ),
      );
      editor.selectAll();
      editor.copy();
      editor.open(ScreenDocument.empty('B').copy(width: 400));
      expect(editor.canPaste, isTrue);
      expect(editor.paste, throwsFormatException);
      expect(editor.document.nodes, isEmpty);
      expect(editor.canUndo, isFalse);
      editor.dispose();
    },
  );
}
