// Native synthetic tests. Web download initiation needs separate browser evidence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_pending_result_test.dart' show PendingTransferApi;

class ExportSelector extends FileSelectorPlatform {
  FileSaveLocation? location;
  Object? failure;
  Completer<FileSaveLocation?>? gate;
  final names = <String?>[];
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    names.add(options.suggestedName);
    if (failure != null) throw failure!;
    return gate == null ? location : await gate!.future;
  }

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile.fromData(Uint8List(0), name: 'synthetic.json');
}

class ExportFeedbackApi extends PendingTransferApi {
  final exports = <Json>[];
  final bytes = Uint8List.fromList(utf8.encode('{"synthetic":true}'));
  @override
  Future<Uint8List> exportProcessTransfer(Json body) async {
    exports.add(jsonDecode(jsonEncode(body)) as Json);
    return bytes;
  }
}

void main() {
  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label).last;
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester,
    ExportFeedbackApi api,
    ExportSelector selector, {
    bool remaining = false,
    Size size = const Size(640, 480),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = selector;
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
                variables: const [
                  {'id': 'v1', 'name': '温度', 'station': '站一'},
                ],
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '打开');
    if (remaining) {
      await tap(tester, '选择文件');
      await tap(tester, '预览');
      await tap(tester, '确认保存');
      expect(api.commitBodies, hasLength(1));
    } else {
      await tester.tap(find.widgetWithText(ChoiceChip, '导出'));
      await tester.pumpAndSettle();
      await tap(tester, '泵房 · 站一');
      await tap(tester, '温度 · 站一');
    }
  }

  void unchanged(WidgetTester tester, ExportFeedbackApi api, bool remaining) {
    if (remaining) {
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('绑定 · screenA/n1/point_id · 失败'), findsOneWidget);
      expect(api.commitBodies, hasLength(1));
      expect(api.exports, isEmpty);
    } else {
      expect(api.commitBodies, isEmpty);
      expect(api.exports.single['screen_ids'], ['s1']);
      expect(api.exports.single['variable_ids'], ['v1']);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '泵房 · 站一'),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '温度 · 站一'),
            )
            .value,
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  }

  for (final remaining in [false, true]) {
    final label = remaining ? '导出剩余清单' : '导出';
    testWidgets(
      '$label cancel explicitly reported and selection/result retained',
      (tester) async {
        final api = ExportFeedbackApi(), picker = ExportSelector();
        await open(tester, api, picker, remaining: remaining);
        await tap(tester, label);
        expect(find.textContaining('已取消保存'), findsOneWidget);
        expect(picker.names, hasLength(1));
        unchanged(tester, api, remaining);
        if (remaining) {
          await tap(tester, '更换导入文件');
          expect(find.text('预览'), findsOneWidget);
        } else {
          await tester.tap(find.widgetWithText(ChoiceChip, '导入'));
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('已取消保存'), findsNothing);
      },
    );
    testWidgets('$label save error is caught without replay', (tester) async {
      final api = ExportFeedbackApi(),
          picker = ExportSelector()
            ..failure = const FileSystemException('synthetic save failure');
      await open(tester, api, picker, remaining: remaining);
      await tap(tester, label);
      expect(find.textContaining('synthetic save failure'), findsOneWidget);
      expect(find.text('文件已保存。'), findsNothing);
      unchanged(tester, api, remaining);
    });
    testWidgets(
      '$label pending save disables repeated action and cancellation restores',
      (tester) async {
        final api = ExportFeedbackApi(),
            picker = ExportSelector()..gate = Completer<FileSaveLocation?>();
        await open(tester, api, picker, remaining: remaining);
        final action = remaining
            ? tester
                  .widget<TextButton>(find.widgetWithText(TextButton, label))
                  .onPressed!
            : tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, label),
                  )
                  .onPressed!;
        action();
        action();
        await tester.pumpAndSettle();
        expect(
          remaining
              ? tester
                    .widget<TextButton>(find.widgetWithText(TextButton, label))
                    .onPressed
              : tester
                    .widget<FilledButton>(find.byType(FilledButton))
                    .onPressed,
          isNull,
        );
        expect(api.exports, hasLength(remaining ? 0 : 1));
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
              .onPressed,
          isNull,
        );
        expect(picker.names, hasLength(1));
        picker.gate!.complete(null);
        await tester.pumpAndSettle();
        expect(find.textContaining('已取消保存'), findsOneWidget);
        unchanged(tester, api, remaining);
      },
    );
    testWidgets(
      '$label success writes only synthetic native bytes before success feedback',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'hmi-transfer-save-fixture-',
        );
        addTearDown(() => temp.deleteSync(recursive: true));
        final file = File('${temp.path}/synthetic.json');
        final api = ExportFeedbackApi(),
            picker = ExportSelector()..location = FileSaveLocation(file.path);
        await open(tester, api, picker, remaining: remaining);
        final target = find.text(label).last;
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        // Native XFile.saveTo performs real I/O, outside the fake clock.
        await tester.runAsync(() async {
          await tester.tap(target);
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while ((!file.existsSync() || file.lengthSync() == 0) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(file.existsSync(), isTrue);
        // The user-selected path differs from the suggested name. Feedback must not invent the saved filename.
        expect(find.textContaining('已保存文件：process-'), findsNothing);
        if (remaining) {
          final decoded = jsonDecode(file.readAsStringSync()) as Map;
          expect(decoded['retry_request'], api.commitBodies.single);
          expect(picker.names.single, 'process-transfer-remaining.json');
        } else {
          expect(file.readAsBytesSync(), orderedEquals(api.bytes));
          expect(picker.names.single, 'process-bundle.json');
        }
        expect(find.text('文件已保存。'), findsOneWidget);
        unchanged(tester, api, remaining);
      },
    );
  }
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets(
      'long save error stays scrollable with fixed actions at $size',
      (tester) async {
        final api = ExportFeedbackApi();
        final picker = ExportSelector()
          ..failure = FileSystemException(
            List.filled(40, '合成保存失败详情，请选择可写的目标位置。').join(),
          );
        await open(tester, api, picker, size: size);
        await tap(tester, '导出');
        expect(tester.takeException(), isNull);
        expect(
          find.widgetWithText(FilledButton, '导出').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextButton, '关闭').hitTestable(),
          findsOneWidget,
        );
        final viewport = find.byType(SingleChildScrollView).first;
        expect(tester.getSize(viewport).height, greaterThanOrEqualTo(80));
        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '搜索导出变量',
        );
        expect(
          tester.getRect(search).right,
          lessThanOrEqualTo(tester.getRect(viewport).right - 12),
        );
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(of: viewport, matching: find.byType(Scrollable))
              .first,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        unchanged(tester, api, false);
      },
    );
  }
}
