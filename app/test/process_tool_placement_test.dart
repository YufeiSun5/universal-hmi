import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/canvas.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_test.dart' show ScreenApi;

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets('drawing tools and panel controls stay usable at $size', (
      tester,
    ) async {
      await tester.runAsync(() => processSymbols);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ProcessSession('A')..loaded = true;
      session.controller.add(
        ScreenElement.create('rect', const Offset(100, 100)),
      );
      final before = jsonEncode(session.controller.document.toJson());
      final selection = session.controller.selectedID;
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
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
      for (final key in [
        'process-tool-select',
        'process-tool-hand',
        'process-tool-pipe',
      ]) {
        expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
      }
      expect(find.byTooltip('显示素材库').hitTestable(), findsOneWidget);
      expect(find.byTooltip('显示属性').hitTestable(), findsOneWidget);
      expect(find.byTooltip('画面文件').hitTestable(), findsOneWidget);
      if (size.width < 880) {
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('process-symbol-library')), findsNothing);
        expect(
          tester.getSize(find.byType(ProcessCanvas)).width,
          closeTo(size.width - 244, 1),
        );
        await tester.tap(find.byTooltip('显示素材库'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const Key('process-symbol-search')),
        'Pipe',
      );
      await tester.pumpAndSettle();
      final width = tester.getSize(find.byType(ProcessCanvas)).width;
      await tester.tap(find.byTooltip('显示素材库'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ProcessCanvas)).width,
        greaterThan(width + 180),
      );
      await tester.tap(find.byTooltip('显示素材库'));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byKey(const Key('process-symbol-search')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(input).controller.text, 'Pipe');
      if (size.width < 880) {
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('process-symbol-library')), findsNothing);
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(ProcessCanvas)).width,
          greaterThan(width + 180),
        );
      }
      expect(jsonEncode(session.controller.document.toJson()), before);
      expect(session.controller.selectedID, selection);
      expect(session.controller.dirty, isTrue);
      if (size.width < 880) {
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        final name = find.descendant(
          of: find.byKey(const ValueKey('screen-name')),
          matching: find.byType(TextField),
        );
        await tester.enterText(name, '切面板前未提交的画面名称');
        expect(session.controller.document.name, isNot('切面板前未提交的画面名称'));
        await tester.tap(find.byTooltip('显示素材库'));
        await tester.pumpAndSettle();
        expect(session.controller.document.name, '切面板前未提交的画面名称');
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(name).controller!.text, '切面板前未提交的画面名称');
        await tester.enterText(name, '关闭属性前的第二次输入');
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(session.controller.document.name, '关闭属性前的第二次输入');
        await tester.tap(find.byTooltip('显示属性'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(name).controller!.text, '关闭属性前的第二次输入');
        expect(session.controller.selectedID, selection);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
}
