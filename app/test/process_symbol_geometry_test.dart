import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/scene.dart';
import 'package:universal_hmi/features/process/symbol_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'square exchanger ports touch nozzles, follow resize and rotation, undo restores',
    () {
      final device = ScreenElement.create(
        'symbol',
        const Offset(100, 100),
        symbol: 'example_plate_hx',
      );
      final editor = ProcessController(
        ScreenDocument.empty('A').copy(nodes: [device]),
      );
      addTearDown(editor.dispose);
      const port = Offset(115.625, 120.3125);
      expect(editor.document.port(device.id, 'left_top'), port);
      expect(editor.connection(port, 2)?.$2, 'left_top');
      expect(
        editor.connection(const Offset(100, 120), 2),
        isNull,
        reason: 'empty margin must not attract a pipe',
      );
      editor.addPipe(
        [const Offset(50, 120.3125), port],
        end: (device.id, 'left_top', port),
        orthogonal: false,
      );
      final pipe = editor.selected!;
      editor.update(
        device.update({'width': 220.0, 'height': 160.0, 'rotation': 90}),
      );
      expect(
        editor.document.pipePoints(pipe).last,
        const Offset(275.3125, 104.375),
      );
      expect(
        editor.connection(const Offset(275.3125, 104.375), 1)?.$1,
        device.id,
      );
      editor.undo();
      expect(editor.document.pipePoints(pipe).last, port);
      final loaded = ScreenDocument.fromJson(editor.document.toJson());
      expect(loaded.pipePoints(loaded.nodes.last).last, port);
    },
  );

  test(
    'imported SVG ports use fitted viewports and stable sides rotate with artwork',
    () {
      const rect = Rect.fromLTWH(0, 0, 200, 70);
      final viewport = symbolContentRect('fuxa_77bd1e452078b29e', rect, 0);
      expect(viewport.width, 200);
      expect(viewport.height, closeTo(200 * 31 / 101, 1e-9));
      expect(
        symbolPortPoint('fuxa_77bd1e452078b29e', rect, 0, 'top'),
        viewport.topCenter,
      );
      expect(
        symbolPortPoint('example_plate_hx', rect, 180, 'left_top'),
        const Offset(124.0625, 55.78125),
      );
      expect(symbolPortPoint('unknown', rect, 0, 'left'), rect.centerLeft);
    },
  );

  testWidgets(
    'rendered pipes meet authored equipment contacts with no white gap at every rotation',
    (tester) async {
      final loaded = await tester.runAsync(ProcessSymbol.load);
      final symbols = {for (final symbol in loaded!) symbol.id: symbol};
      const boundaryKey = Key('symbol-contact-raster');
      for (final (symbol, rotation) in [
        for (final id in [
          'example_plate_hx',
          'example_pump',
          'example_tank',
          'example_valve',
        ])
          for (final angle in [0, 90, 180, 270]) (id, angle),
      ]) {
        final device = ScreenElement.create(
          'symbol',
          const Offset(110, 110),
          symbol: symbol,
        ).update({'width': 120.0, 'height': 100.0, 'rotation': rotation});
        final doc = ScreenDocument.empty('A').copy(nodes: [device]);
        final pipes = <ScreenElement>[];
        for (final side in doc.ports(device)) {
          final port = doc.port(device.id, side);
          final normal = side.startsWith('left')
              ? const Offset(-1, 0)
              : side.startsWith('right')
              ? const Offset(1, 0)
              : side == 'top'
              ? const Offset(0, -1)
              : const Offset(0, 1);
          final direction = switch (rotation) {
            90 => Offset(-normal.dy, normal.dx),
            180 => -normal,
            270 => Offset(normal.dy, -normal.dx),
            _ => normal,
          };
          pipes.add(
            ScreenElement.create('pipe', Offset.zero).withPoints(
              [port + direction * 50, port],
              changes: {
                'end_node': device.id,
                'end_port': side,
                'arrow': false,
              },
            ),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 360,
                  height: 320,
                  child: ProcessScene(
                    document: doc.copy(nodes: [...pipes, device]),
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
        final bytes = await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
              .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes!;
        });
        for (final pipe in pipes) {
          final port = doc.port(device.id, pipe.endPort);
          final direction = (pipe.points.first - port) / 50;
          // Scan further into the equipment than the 6px round pipe cap.
          // The cap must not mask a misplaced anchor over empty SVG margins.
          for (var step = -8; step <= 6; step++) {
            final pixel = port + direction * step.toDouble();
            final i = (pixel.dy.round() * 360 + pixel.dx.round()) * 4;
            final sum =
                bytes!.getUint8(i) +
                bytes.getUint8(i + 1) +
                bytes.getUint8(i + 2);
            expect(
              sum,
              lessThan(740),
              reason:
                  'symbol=$symbol rotation=$rotation side=${pipe.endPort} step=$step',
            );
          }
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
}
