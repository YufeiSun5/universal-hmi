import 'dart:convert';
import 'dart:io';
// Reuse the federated file-selector seam; no actual desktop picker is opened.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_test.dart' show ScreenApi;
import 'process_pipe_test.dart' show rule, comparison;

class _RoundtripPicker extends FileSelectorPlatform {
  _RoundtripPicker(this.path);
  final String path;
  int saves = 0, opens = 0;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    saves++;
    expect(options.suggestedName, 'process-screen.json');
    return FileSaveLocation(path);
  }

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    opens++;
    return XFile(path);
  }
}

void main() {
  testWidgets(
    'actual template JSON file roundtrip retains layout but clears live bindings',
    (tester) async {
      await tester.runAsync(() => processSymbols);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('hmi-template-roundtrip-'),
      );
      final file = File('${directory!.path}/process-screen.json');
      addTearDown(() {
        directory.deleteSync(recursive: true);
      });
      final previousPicker = FileSelectorPlatform.instance;
      final picker = _RoundtripPicker(file.path);
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = previousPicker);
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGP0qJjNgA0wYRUdtBIAEyYBa74a5twAAAAASUVORK5CYII=';
      final value = ScreenElement.create('value', const Offset(50, 50)).update({
        'point_id': 'temperature-A',
        'text': '进水温度',
        'unit_override': '℃',
        'decimals': 2,
      });
      final pipe = ScreenElement.create('pipe', Offset.zero).withPoints(
        [const Offset(100, 200), const Offset(400, 200)],
        changes: {
          'point_id': 'flow-A',
          'arrow_mode': 'spacing',
          'arrow_spacing': 72.0,
          'arrow_visible_rule': rule('all', [
            comparison('pressure-A', '>', 10),
          ]),
          'arrow_motion_rule': rule('any', [comparison('flow-A', '>', 0)]),
        },
      );
      final image = ScreenElement.create(
        'image',
        const Offset(450, 50),
        image: 'photo',
      );
      final document = ScreenDocument(
        id: 'source-screen',
        name: '合成换热站工艺',
        station: 'A',
        revision: 7,
        width: 640,
        height: 480,
        background: {'type': 'solid', 'color': '#eef4ff', 'opacity': 1.0},
        nodes: [value, pipe, image],
        assets: {'photo': EmbeddedImage('synthetic.png', 'image/png', png)},
      );
      final source = ProcessSession('A')..loaded = true;
      source.controller.open(document);
      final original = jsonEncode(document.toJson());
      final sourceApi = ScreenApi();
      Future<void> mount(ProcessSession session, ScreenApi api) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: ProcessWorkspace(
                api: api,
                session: session,
                station: session.station,
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

      Future<void> menu(String label) async {
        await tester.ensureVisible(find.byTooltip('画面文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('画面文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      Future<void> waitForUI(String text) async {
        for (var attempt = 0; attempt < 300; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (find.textContaining(text).evaluate().isNotEmpty) return;
        }
        fail(
          'Local file operation did not reach UI result: $text; messages: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).where((v) => v?.contains("导入") == true).toList()}; picked=${picker.opens}',
        );
      }

      await mount(source, sourceApi);
      await menu('导出模板 JSON');
      await waitForUI('模板已导出');
      expect(picker.saves, 1);
      final exported = ScreenDocument.fromJson(
        jsonDecode((await tester.runAsync(file.readAsString))!) as Json,
      );
      expect(exported.station, '');
      expect(exported.revision, 0);
      expect(exported.width, document.width);
      expect(exported.height, document.height);
      final expectedPipe = jsonDecode(jsonEncode(pipe.data)) as Json;
      expectedPipe['point_id'] = '';
      for (final key in ['arrow_visible_rule', 'arrow_motion_rule']) {
        for (final condition in expectedPipe[key]['conditions'] as List) {
          condition['point_id'] = '';
        }
      }
      expect(exported.nodes.map((n) => n.data).toList(), [
        {...value.data, 'point_id': ''},
        expectedPipe,
        image.data,
      ]);
      expect(
        exported.assets.map((k, v) => MapEntry(k, v.toJson())),
        document.assets.map((k, v) => MapEntry(k, v.toJson())),
      );
      expect(exported.nodes.first.pointID, '');
      final exportedPipe = exported.nodes.singleWhere((n) => n.kind == 'pipe');
      expect(exportedPipe.pointID, '');
      expect(
        objects(
          exportedPipe.arrowVisibleRule!['conditions'],
        ).single['point_id'],
        '',
      );
      expect(
        objects(exportedPipe.arrowMotionRule!['conditions']).single['point_id'],
        '',
      );
      expect(
        objects(exportedPipe.arrowVisibleRule!['conditions']).single['slot'],
        '测试变量',
      );
      expect(exportedPipe.arrowSpacing, 72);
      expect(exported.background, document.background);
      expect(exported.assets['photo']!.data, png);
      expect(jsonEncode(source.controller.document.toJson()), original);
      expect(sourceApi.savedScreen, isNull);
      await tester.pumpWidget(const SizedBox());
      source.dispose();
      final target = ProcessSession('B')..loaded = true;
      final targetApi = ScreenApi();
      await mount(target, targetApi);
      await menu('导入模板 JSON');
      await waitForUI('已导入到目标站点');
      final imported = target.controller.document;
      expect(picker.opens, 1);
      expect(imported.id, isNot(document.id));
      expect(imported.station, 'B');
      expect(imported.revision, 0);
      expect(
        imported.nodes.map((n) => n.data).toList(),
        exported.nodes.map((n) => n.data).toList(),
      );
      expect(imported.background, exported.background);
      expect(imported.assets['photo']!.data, png);
      expect(imported.nodes.first.x, 50);
      expect(imported.nodes.first.unitOverride, '℃');
      expect(imported.nodes.first.decimals, 2);
      expect(target.controller.dirty, isTrue);
      expect(targetApi.savedScreen, isNull);
      await tester.tap(find.byKey(const Key('process-save')));
      await tester.pumpAndSettle();
      expect(targetApi.savedScreen, imported.toJson());
      expect(targetApi.savedScreen!['station'], 'B');
      expect(target.controller.dirty, isFalse);
      expect(target.controller.document.revision, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      target.dispose();
    },
  );
}
