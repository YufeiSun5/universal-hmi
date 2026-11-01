import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_test.dart' show ScreenApi;
import 'workspace_test.dart' show launch;
import 'package:universal_hmi/features/process/model.dart';

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
    const Size(420, 240),
  ]) {
    testWidgets('primary process actions remain visible at $size', (
      tester,
    ) async {
      await tester.runAsync(() => processSymbols);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ProcessSession('A')..loaded = true;
      session.controller.commit(
        session.controller.document.copy(name: '这是需要完整保留名称和草稿状态的长工艺画面名称'),
      );
      final api = ScreenApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
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
      expect(
        find.byKey(const Key('process-save')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('process-preview')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('process-screen-selection')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('process-transfer')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('● 未保存'), findsOneWidget);
      if (size.height < 300) {
        await tester.enterText(
          find.byKey(const Key('process-symbol-search')),
          'Pipe',
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('process-symbol-library')),
          const Offset(0, -190),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(Draggable<ProcessSymbol>).hitTestable(),
          findsWidgets,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.drag(
          find.byKey(const Key('process-symbol-library')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('process-symbol-library')),
          const Offset(0, 1200),
        );
        await tester.pumpAndSettle();
        final searchField = find.descendant(
          of: find.byKey(const Key('process-symbol-search')),
          matching: find.byType(EditableText),
        );
        expect(
          tester.widget<EditableText>(searchField).controller.text,
          'Pipe',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        return;
      }
      final draft = jsonEncode(session.controller.document.toJson());
      await tester.tap(find.byKey(const Key('process-preview')));
      await tester.pumpAndSettle();
      expect(session.controller.editing, isFalse);
      expect(jsonEncode(session.controller.document.toJson()), draft);
      await tester.tap(find.byKey(const Key('process-preview')));
      await tester.pumpAndSettle();
      expect(session.controller.editing, isTrue);
      await tester.tap(find.byKey(const Key('process-transfer')));
      await tester.pumpAndSettle();
      expect(find.byType(ProcessTransferDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '关闭').last);
      await tester.pumpAndSettle();
      expect(find.byType(ProcessTransferDialog), findsNothing);
      expect(jsonEncode(session.controller.document.toJson()), draft);
      expect(session.controller.dirty, isTrue);
      expect(api.savedScreen, isNull);
      await tester.tap(find.byKey(const Key('process-save')));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.savedScreen), draft);
      expect(session.controller.dirty, isFalse);
      expect(session.controller.document.revision, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
  testWidgets('real developer shell keeps primary commands after resize', (
    tester,
  ) async {
    final api = ScreenApi();
    api.rows.add(api.point('a', 'A'));
    api.screens['A1'] = ScreenDocument(
      id: 'A1',
      name: 'A 工艺图',
      station: 'A',
      revision: 1,
    ).toJson();
    await tester.runAsync(() => processSymbols);
    await launch(tester, api, size: const Size(1280, 800));
    await tester.tap(find.byKey(const Key('station-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screen-resource-A1')));
    await tester.pumpAndSettle();
    for (final size in [const Size(640, 480)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      for (final key in [
        'process-save',
        'process-preview',
        'process-transfer',
        'process-screen-selection',
      ]) {
        expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
