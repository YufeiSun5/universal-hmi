import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/background_editor.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/diagram.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/presentation.dart';
import 'package:universal_hmi/features/process/scene.dart';
import 'package:universal_hmi/platform/process_files.dart';

ScreenDocument document() => ScreenDocument(
  id: 'drawing',
  name: '背景测试',
  station: '',
  width: 320,
  height: 240,
  nodes: [
    ScreenElement.create('rect', Offset.zero).update({
      'id': 'monitor-backdrop',
      'width': 320.0,
      'height': 240.0,
      'fill': '#162f45',
      'color': '#162f45',
    }),
    ScreenElement.create('rect', const Offset(20, 20)).update({
      'id': 'equipment',
      'width': 40.0,
      'height': 40.0,
      'fill': '#ff0000',
      'color': '#ff0000',
    }),
  ],
);

Future<Uint8List> validPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const Color(0xff0099ff),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('background null and GIS configuration are rejected consistently', () {
    expect(
      () =>
          ScreenDocument.fromJson({...document().toJson(), 'background': null}),
      throwsFormatException,
    );
    expect(
      () => ScreenDocument(
        id: 'gis',
        name: '地图',
        station: '',
        kind: 'gis',
        background: {'type': 'solid', 'color': '#ffffff', 'opacity': 1},
      ).checkGeometry(),
      throwsFormatException,
    );
  });
  testWidgets(
    'validated PNG embeds and image to solid prunes only obsolete background assets',
    (tester) async {
      final bytes = (await tester.runAsync(validPng))!;
      final asset = await tester.runAsync(
        () => backgroundImage(ProcessFile('背景.png', bytes)),
      );
      expect(asset!.mime, 'image/png');
      final source = document();
      final doc = source.copy(
        background: {
          'type': 'image',
          'color': '#ffffff',
          'opacity': 1.0,
          'image': 'old-background',
          'fit': 'cover',
        },
        assets: {'old-background': asset, 'node-image': asset},
        nodes: [
          ...source.nodes,
          ScreenElement.create(
            'image',
            const Offset(80, 80),
            image: 'node-image',
          ),
        ],
      );
      ScreenDocument? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await editProcessBackground(context, doc);
                },
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纯色').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-apply')));
      await tester.pumpAndSettle();
      expect(result!.background!['type'], 'solid');
      expect(result!.assets.keys, ['node-image']);
      expect(result!.toJson()['assets'], {'node-image': asset.toJson()});
      expect(
        ScreenDocument.fromJson(result!.toJson()).background,
        result!.background,
      );
      expect(doc.assets.length, 2);
    },
  );
  test(
    'background persists through serialization copies history and linked inheritance',
    () {
      final bg = {
        'type': 'image',
        'color': '#123456',
        'opacity': 0.4,
        'image': 'background',
        'fit': 'contain',
      };
      final doc = document().copy(
        background: bg,
        assets: {'background': EmbeddedImage('背景.png', 'image/png', 'YQ==')},
      );
      final restored = ScreenDocument.fromJson(
        jsonDecode(jsonEncode(doc.toJson())),
      );
      expect(restored.background, bg);
      expect(restored.instantiate('B').background, bg);
      expect(restored.toTemplate().background, bg);
      expect(restored.instantiate('B').assets['background']!.data, 'YQ==');
      expect(
        restored.copy(templateID: 'public').toJson().containsKey('background'),
        isFalse,
      );
      final controller = ProcessController(document())..open(document());
      controller.commit(doc);
      expect(controller.dirty, isTrue);
      controller.select('equipment');
      controller.removeSelected();
      expect(controller.document.assets.containsKey('background'), isTrue);
      controller.undo();
      controller.undo();
      expect(controller.document.background, isNull);
      controller.redo();
      expect(controller.document.background, bg);
      controller.dispose();
    },
  );

  testWidgets(
    'opacity affects only background pixels with a shared white base',
    (tester) async {
      final key = GlobalKey();
      for (final opacity in [0.0, 0.5]) {
        final doc = document().copy(
          background: {'type': 'solid', 'color': '#0000ff', 'opacity': opacity},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: ProcessScene(
                    document: doc,
                    symbols: const {},
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
        final image = await tester.runAsync(
          () =>
              (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
                  .toImage(),
        );
        final pixels = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final bytes = pixels!.buffer.asUint8List();
        List<int> pixel(int x, int y) =>
            bytes.sublist((y * 320 + x) * 4, (y * 320 + x) * 4 + 4);
        expect(pixel(40, 40), [255, 0, 0, 255]);
        expect(
          pixel(200, 200),
          opacity == 0 ? [255, 255, 255, 255] : [127, 127, 255, 255],
        );
        image!.dispose();
      }
    },
  );

  testWidgets(
    'canvas and embedded diagram share legacy scene and ignore hidden backdrop hits',
    (tester) async {
      final doc = document();
      final before = jsonEncode(doc.toJson());
      final controller = ProcessController(doc)..grid = false;
      final canvasKey = GlobalKey<ProcessCanvasState>();
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: ProcessCanvas(
                    key: canvasKey,
                    controller: controller,
                    symbols: const {},
                    definitions: const {},
                    live: const {},
                    online: true,
                    tool: 'select',
                    onToolDone: () {},
                    onSave: () {},
                  ),
                ),
                Expanded(
                  child: ProcessDiagram(
                    document: doc,
                    symbols: const {},
                    definitions: const {},
                    live: const {},
                    online: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scenes = tester
          .widgetList<ProcessScene>(find.byType(ProcessScene))
          .toList();
      expect(scenes.length, 2);
      expect(scenes.every((s) => identical(s.document, doc)), isTrue);
      final backgrounds = tester.widgetList<ProcessBackground>(
        find.byType(ProcessBackground),
      );
      expect(backgrounds.length, 2);
      expect(
        backgrounds.every((b) => ProcessPresentation.legacyStyle(b.document)),
        isTrue,
      );
      expect(canvasKey.currentState!.hit(const Offset(250, 180)), isNull);
      expect(
        canvasKey.currentState!.hit(const Offset(40, 40))!.id,
        'equipment',
      );
      expect(jsonEncode(doc.toJson()), before);
      final custom = doc.copy(
        nodes: [
          doc.nodes.first.update({'id': 'user-background'}),
        ],
      );
      expect(
        ProcessPresentation.omitBackdrop(custom, custom.nodes.first),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'invalid upload retains existing image and dialog changes stay local until apply',
    (tester) async {
      final png = (await tester.runAsync(validPng))!;
      final doc = document().copy(
        background: {
          'type': 'image',
          'color': '#ffffff',
          'opacity': 0.5,
          'image': 'bg',
          'fit': 'contain',
        },
        assets: {
          'bg': EmbeddedImage('原背景.png', 'image/png', base64Encode(png)),
        },
      );
      final before = jsonEncode(doc.toJson());
      ScreenDocument? applied;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  applied = await editProcessBackground(
                    context,
                    doc,
                    pickImage: () async =>
                        ProcessFile('无效.png', Uint8List.fromList([1, 2, 3])),
                  );
                },
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('background-upload')));
      await tester.tap(find.byKey(const Key('background-upload')));
      await tester.pumpAndSettle();
      expect(find.textContaining('原背景保持'), findsOneWidget);
      expect(find.text('原背景.png'), findsOneWidget);
      await tester.tap(find.byKey(const Key('background-apply')));
      await tester.pumpAndSettle();
      expect(applied!.background, doc.background);
      expect(applied!.assets['bg']!.data, doc.assets['bg']!.data);
      expect(jsonEncode(doc.toJson()), before);
    },
  );
}
