import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/materials.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/platform/process_files.dart';
import 'package:universal_hmi/shared/api.dart';

class MaterialApi extends Fake implements PlatformApi {
  Json? saved;
  int reads = 0;
  bool reject = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (method == 'PUT') {
      return saved = {...body as Json, 'revision': 1, 'width': 2, 'height': 2};
    }
    if (method == 'DELETE') {
      saved = null;
      return {};
    }
    if (path == '/api/v1/process-materials') {
      return {
        'items': saved == null ? [] : [saved],
      };
    }
    reads++;
    if (reject) throw const PlatformRequestException(503, 'offline');
    return saved!;
  }
}

void main() {
  test('upload retains original PNG bytes and failed fetch can retry', () async {
    final api = MaterialApi();
    final state = ProcessMaterialLibrary(api);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
    );
    final material = await state.upload(
      ProcessFile('透明泵.png', bytes),
      '透明泵',
      '设备',
    );
    expect(material.asset.bytes, bytes);
    expect(api.saved!['asset']['data'], base64Encode(bytes));
    expect(state.items.single.name, '透明泵');
    final secondClient = ProcessMaterialLibrary(api);
    await secondClient.refresh();
    api.reject = true;
    await expectLater(
      secondClient.get(secondClient.items.single),
      throwsA(isA<PlatformRequestException>()),
    );
    api.reject = false;
    expect(
      (await secondClient.get(secondClient.items.single)).asset.bytes,
      bytes,
    );
    expect(api.reads, 2);
    await state.delete(material.summary);
    expect(state.items, isEmpty);
    expect(material.asset.bytes, bytes);
    state.dispose();
    secondClient.dispose();
  });

  testWidgets(
    'uploaded artwork uses same canvas drag target and scene coordinates',
    (tester) async {
      final item = ProcessMaterialSummary({
        'id': 'pump',
        'revision': 1,
        'name': 'Pump',
        'category': 'Equipment',
        'width': 120,
        'height': 60,
      });
      final editor = ProcessController(ScreenDocument.empty('A'));
      (ProcessMaterialSummary, Offset)? dropped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: ProcessCanvas(
                    controller: editor,
                    symbols: const {},
                    definitions: const {},
                    live: const {},
                    online: true,
                    tool: 'select',
                    onToolDone: () {},
                    onSave: () {},
                    onMaterialPlaced: (m, p) => dropped = (m, p),
                  ),
                ),
                Draggable<Object>(
                  data: item,
                  feedback: const Text('Pump'),
                  child: const SizedBox(
                    width: 100,
                    height: 50,
                    child: Text('My pump'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.drag(find.text('My pump'), const Offset(0, -200));
      await tester.pump();
      expect(dropped?.$1.id, 'pump');
      expect(dropped!.$2.dx, greaterThanOrEqualTo(0));
      expect(dropped!.$2.dy, greaterThanOrEqualTo(0));
      expect(editor.document.nodes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );
}
