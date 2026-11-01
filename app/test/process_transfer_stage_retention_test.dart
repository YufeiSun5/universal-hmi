import 'dart:async';
import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_pending_result_test.dart' show PendingTransferApi;

class StagePicker extends FileSelectorPlatform {
  Completer<XFile?>? pending;
  int calls = 0;
  XFile? nextFile = XFile.fromData(Uint8List(0), name: 'synthetic.json');
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return pending == null ? nextFile : await pending!.future;
  }
}

class StageApi extends PendingTransferApi {
  bool rejectDecode = false;
  bool includeVariables = false;
  @override
  Future<Json> decodeProcessTransfer(String name, Uint8List bytes) async {
    if (rejectDecode) throw const FormatException('合成损坏文件');
    final decoded = await super.decodeProcessTransfer(name, bytes);
    if (includeVariables) {
      (decoded['bundle'] as Map)['variables'] = List.generate(
        120,
        (i) => {
          'key': 'variable_$i',
          'definition': {'name': '变量$i', 'station': 'A'},
        },
      );
    }
    return decoded;
  }
}

void main() {
  Future<void> tap(WidgetTester tester, String label) async {
    final f = find.text(label).last;
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    expect(f.hitTestable(), findsOneWidget);
    await tester.tap(f);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> open(
    WidgetTester tester,
    StageApi api,
    StagePicker picker,
    int stage,
    Size size,
    VoidCallback onCommitted,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = original);
    await tester.pumpWidget(
      MaterialApp(
        theme: workspaceTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProcessTransfer(
                context,
                api,
                stations: const ['站一'],
                variables: api.includeVariables
                    ? [
                        for (var i = 0; i < 120; i++)
                          {
                            'id': 'export_$i',
                            'name': '出口变量$i',
                            'station': '站一',
                          },
                      ]
                    : const [],
                onCommitted: onCommitted,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '打开');
    await tap(tester, '选择文件');
    await tap(tester, '按文件站名批量映射，不存在时创建站点');
    await tap(tester, '批量更新同一导入身份的画面');
    if (stage >= 2) await tap(tester, '预览');
    if (stage == 3) await tap(tester, '确认保存');
  }

  void checkStage(WidgetTester tester, int stage) {
    expect(
      find.text(
        stage == 1
            ? '预览'
            : stage == 2
            ? '确认保存'
            : '已完成',
      ),
      findsOneWidget,
    );
    if (stage == 3) {
      expect(find.text('绑定 · screenA/n1/point_id · 失败'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '已完成'))
            .onPressed,
        isNull,
      );
    }
  }

  for (final stage in [1, 2, 3]) {
    for (final size in [
      const Size(1280, 800),
      const Size(640, 480),
      const Size(420, 360),
    ]) {
      testWidgets('import stage $stage survives export view at $size', (
        tester,
      ) async {
        final api = StageApi(), picker = StagePicker();
        var refreshes = 0;
        await open(tester, api, picker, stage, size, () => refreshes++);
        final previewCount = api.previewBodies.length,
            commitCount = api.commitBodies.length;
        await tester.tap(find.widgetWithText(ChoiceChip, '导出'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '导入'));
        await tester.pumpAndSettle();
        checkStage(tester, stage);
        expect(find.text('更换导入文件').hitTestable(), findsOneWidget);
        expect(api.previewBodies, hasLength(previewCount));
        expect(api.commitBodies, hasLength(commitCount));
        expect(refreshes, stage == 3 ? 1 : 0);
        if (stage == 1) {
          await tap(tester, '预览');
          expect(api.lastPreview!['station_map'], {'A': 'A'});
          expect(api.lastPreview!['screen_targets'], {
            'screenA': {'mode': 'update_imported'},
          });
        }
        if (stage == 2) {
          api.failCommit = true;
          await tap(tester, '确认保存');
          expect(find.text('确认保存'), findsNothing);
          expect(find.text('预览'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('new file only replaces stage $stage after successful decode', (
      tester,
    ) async {
      final api = StageApi(), picker = StagePicker();
      var refreshes = 0;
      await open(
        tester,
        api,
        picker,
        stage,
        const Size(1280, 800),
        () => refreshes++,
      );
      final oldCommits = api.commitBodies.length;
      picker.nextFile = null;
      await tap(tester, '更换导入文件');
      checkStage(tester, stage);
      expect(api.commitBodies, hasLength(oldCommits));
      picker.nextFile = XFile.fromData(Uint8List(0), name: 'bad.json');
      api.rejectDecode = true;
      await tap(tester, '更换导入文件');
      checkStage(tester, stage);
      expect(find.textContaining('解析失败'), findsOneWidget);
      expect(api.commitBodies, hasLength(oldCommits));
      api.rejectDecode = false;
      picker.nextFile = XFile.fromData(Uint8List(0), name: 'new.json');
      await tap(tester, '更换导入文件');
      checkStage(tester, 1);
      expect(find.text('确认保存'), findsNothing);
      await tap(tester, '预览');
      expect(api.lastPreview!['station_map'], isEmpty);
      expect(api.lastPreview!['screen_targets'], {
        'screenA': {'mode': 'create'},
      });
      expect(api.lastPreview!['import_identity'], 'process-transfer-v1');
      expect(api.commitBodies, hasLength(oldCommits));
      expect(refreshes, stage == 3 ? 1 : 0);
    });
  }
  Finder searchField(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  String inputValue(WidgetTester tester, Finder field) => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .controller
      .text;
  Future<void> search(WidgetTester tester, String label, String text) async {
    final field = searchField(label);
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Future<void> switchMode(WidgetTester tester, String mode) async {
    await tester.tap(find.widgetWithText(ChoiceChip, mode));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mode searches are visible independent and new file clears only import',
    (tester) async {
      final api = StageApi()..includeVariables = true;
      final picker = StagePicker();
      await open(tester, api, picker, 1, const Size(1280, 800), () {});
      await search(tester, '搜索导入画面', 'screenA');
      await search(tester, '搜索导入变量', 'variable_5');
      await switchMode(tester, '导出');
      expect(inputValue(tester, searchField('搜索导出变量')), '');
      expect(find.text('出口变量0 · 站一'), findsOneWidget);
      await search(tester, '搜索导出变量', '出口变量1');
      await switchMode(tester, '导入');
      checkStage(tester, 1);
      expect(inputValue(tester, searchField('搜索导入变量')), 'variable_5');
      expect(inputValue(tester, searchField('搜索导入画面')), 'screenA');
      expect(find.text('变量：变量5 · variable_5'), findsOneWidget);
      expect(find.text('变量：变量6 · variable_6'), findsNothing);
      picker.nextFile = null;
      await tap(tester, '更换导入文件');
      expect(inputValue(tester, searchField('搜索导入变量')), 'variable_5');
      expect(inputValue(tester, searchField('搜索导入画面')), 'screenA');
      picker.nextFile = XFile.fromData(Uint8List(0), name: 'new.json');
      await tap(tester, '更换导入文件');
      expect(inputValue(tester, searchField('搜索导入变量')), '');
      expect(inputValue(tester, searchField('搜索导入画面')), '');
      expect(find.text('变量：变量0 · variable_0'), findsOneWidget);
      await switchMode(tester, '导出');
      expect(inputValue(tester, searchField('搜索导出变量')), '出口变量1');
      expect(find.text('出口变量0 · 站一'), findsNothing);
    },
  );
  testWidgets('mode page numbers do not leak into each other', (tester) async {
    final api = StageApi()..includeVariables = true;
    await open(tester, api, StagePicker(), 1, const Size(1280, 800), () {});
    await tap(tester, '下一页');
    expect(find.text('变量：变量50 · variable_50'), findsOneWidget);
    await switchMode(tester, '导出');
    expect(find.text('出口变量0 · 站一'), findsOneWidget);
    expect(find.text('出口变量50 · 站一'), findsNothing);
    await switchMode(tester, '导入');
    expect(find.text('变量：变量50 · variable_50'), findsOneWidget);
    expect(find.text('变量：变量0 · variable_0'), findsNothing);
  });
  testWidgets(
    'pending replacement keeps prior stage and disables competing actions',
    (tester) async {
      final api = StageApi(), picker = StagePicker();
      await open(tester, api, picker, 2, const Size(640, 480), () {});
      final pending = Completer<XFile?>();
      picker.pending = pending;
      await tap(tester, '更换导入文件');
      expect(picker.calls, 2);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '更换导入文件'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '导出'))
            .onSelected,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(api.commitBodies, isEmpty);
      pending.complete(null);
      await tester.pumpAndSettle();
      checkStage(tester, 2);
      expect(find.text('更换导入文件').hitTestable(), findsOneWidget);
      expect(api.previewBodies, hasLength(1));
      expect(api.commitBodies, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
