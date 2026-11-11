// Stage inside app/test to render delivery documents with the production scene.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/scene.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Imported lamps and levels render through the production scene', (
    tester,
  ) async {
    final folder = Platform.environment['PIC_REFRESH_DIR']!;
    final font = FontLoader('HmiCJK')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await tester.runAsync(() => font.load());
    final loaded = await tester.runAsync(() => ProcessSymbol.load());
    final symbols = {for (final s in loaded!) s.id: s};
    final bundle = jsonDecode(File('$folder/screens.json').readAsStringSync());
    final images = Directory('$folder/previews')..createSync();
    final sizes = <Map<String, dynamic>>[];
    for (final entry in bundle['screens']) {
      final original = ScreenDocument.fromJson(entry['document']);
      final pointIDs = <String, String>{
        for (final binding in bundle['bindings'])
          if (binding['screen_key'] == entry['key'] &&
              binding['operation'] == 'set')
            binding['node_id']: binding['variable_key'],
      };
      final doc = original.copy(
        nodes: [
          for (final n in original.nodes)
            n.update({'point_id': pointIDs[n.id] ?? ''}),
        ],
      );
      final definitions = <String, Map<String, dynamic>>{
        for (final v in bundle['variables'])
          v['key']: Map<String, dynamic>.from(v['definition']),
      };
      final values = <String, Map<String, dynamic>>{};
      int lampNumber = 0;
      for (final n in doc.nodes) {
        if (n.pointID.isEmpty) continue;
        values[n.pointID] = {
          'quality': 'good',
          'value': n.stateDisplay != null
              ? (++lampNumber % 2 == 0)
              : n.kind == 'level'
              ? 1.5
              : 12.3,
        };
      }
      for (final n in doc.nodes.where((n) => n.kind == 'level')) {
        values[n.pointID] = {'quality': 'good', 'value': 1.5};
      }

      doc.checkGeometry();
      expect(
        doc.nodes
            .where((n) => n.stateDisplay != null || n.kind == 'level')
            .every((n) => n.pointID.isNotEmpty),
        isTrue,
      );
      final key = GlobalKey();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(doc.width, doc.height);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'HmiCJK'),
          home: Material(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: doc.width,
                height: doc.height,
                child: ProcessScene(
                  document: doc,
                  symbols: symbols,
                  definitions: definitions,
                  live: values,
                  online: true,
                  compactUnboundValues: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (final asset in doc.assets.values) {
          await precacheImage(MemoryImage(asset.bytes), key.currentContext!);
        }
        for (final node in doc.nodes.where((n) => n.kind == 'symbol')) {
          final symbol = symbols[node.symbol];
          if (symbol != null && symbol.raster) {
            await precacheImage(AssetImage(symbol.path), key.currentContext!);
          }
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: doc.name);
      expect(find.text('图片无法读取'), findsNothing, reason: doc.name);
      expect(find.text('图片缺失'), findsNothing, reason: doc.name);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${images.path}/${doc.station}.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
      sizes.add({
        'station': doc.station,
        'width': doc.width,
        'height': doc.height,
      });
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    File('$folder/render-verification.json').writeAsStringSync(
      jsonEncode({
        'renderer': 'production Flutter ProcessScene',
        'real_live_data': false,
        'screens': sizes,
      }),
    );
  });
}
