import 'dart:async';
import 'dart:convert';

// Same federated file-picker testing seam as history_filter_race_test.dart.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_test.dart' show TransferTestApi;

class SyntheticTransferPicker extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile.fromData(Uint8List(0), name: 'synthetic-process.json');
}

class PendingTransferApi extends TransferTestApi {
  Completer<Json>? pendingCommit;
  bool failCommit = false;
  final commitBodies = <Json>[];
  final previewBodies = <Json>[];

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/preview')) {
      previewBodies.add(jsonDecode(jsonEncode(body)) as Json);
      final value = await super.request(method, path, body: body, query: query);
      return {...value, 'preview_token': 'preview-${previewBodies.length}'};
    }
    if (path.endsWith('/commit')) {
      commitBodies.add(jsonDecode(jsonEncode(body)) as Json);
      if (pendingCommit != null) return pendingCommit!.future;
      if (failCommit) throw StateError('提交响应未收到');
    }
    return super.request(method, path, body: body, query: query);
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
    expect(tester.takeException(), isNull);
  }

  Future<void> open(
    WidgetTester tester,
    PendingTransferApi api,
    VoidCallback refreshed, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = SyntheticTransferPicker();
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
                station: '站一',
                stations: const ['站一'],
                onCommitted: refreshed,
              ),
              child: const Text('打开工艺传输'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '打开工艺传输');
    await tap(tester, '选择文件');
    await tap(tester, '按文件站名批量映射，不存在时创建站点');
    await tap(tester, '批量更新同一导入身份的画面');
    await tap(tester, '预览');
  }

  for (final dismissal in ['barrier', 'escape', 'back']) {
    testWidgets('pending commit retains result route against $dismissal', (
      tester,
    ) async {
      final gate = Completer<Json>();
      final api = PendingTransferApi()..pendingCommit = gate;
      var refreshes = 0;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete({'items': <Json>[]});
      });
      await open(tester, api, () => refreshes++);
      await tap(tester, '确认保存');
      expect(api.commitBodies, hasLength(1));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
            .onPressed,
        isNull,
      );
      if (dismissal == 'barrier') {
        await tester.tapAt(const Offset(4, 4));
      } else if (dismissal == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await Navigator.of(
          tester.element(find.byType(ProcessTransferDialog)),
        ).maybePop();
      }
      await tester.pumpAndSettle();
      expect(find.byType(ProcessTransferDialog), findsOneWidget);
      expect(refreshes, 0);
      gate.complete({
        'items': [
          {'kind': 'screen', 'key': 'screenA', 'status': 'saved'},
          {
            'kind': 'binding',
            'key': 'screenA/n1/point_id',
            'status': 'failed',
            'message': '未匹配',
          },
        ],
        'remaining': [
          {'kind': 'binding', 'key': 'screenA/n1/point_id', 'status': 'failed'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('已保存'), findsOneWidget);
      expect(find.textContaining('失败'), findsOneWidget);
      expect(find.text('剩余 1 项'), findsOneWidget);
      expect(refreshes, 1);
      expect(api.commitBodies, hasLength(1));
      await tap(tester, '关闭');
      expect(find.byType(ProcessTransferDialog), findsNothing);
      expect(refreshes, 1);
    });
  }

  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets(
      'unconfirmed commit requires fresh preview and retains mappings $size',
      (tester) async {
        final api = PendingTransferApi()..failCommit = true;
        var refreshes = 0;
        await open(tester, api, () => refreshes++, size: size);
        final originalPreview = jsonEncode(api.previewBodies.single);
        await tap(tester, '确认保存');
        expect(api.commitBodies, hasLength(1));
        expect(api.commitBodies.single['preview_token'], 'preview-1');
        expect(find.text('确认保存'), findsNothing);
        expect(find.text('预览'), findsOneWidget);
        expect(find.textContaining('重新预览'), findsOneWidget);
        expect(find.textContaining('已有草稿未被替换'), findsNothing);
        expect(refreshes, 0);
        await tester.pump(const Duration(seconds: 1));
        expect(
          api.commitBodies,
          hasLength(1),
          reason: 'An uncertain response must not cause automatic retry',
        );
        api.failCommit = false;
        await tap(tester, '预览');
        expect(jsonEncode(api.previewBodies.last), originalPreview);
        expect(api.previewBodies, hasLength(2));
        await tap(tester, '确认保存');
        expect(api.commitBodies, hasLength(2));
        expect(api.commitBodies.last['preview_token'], 'preview-2');
        expect(refreshes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
