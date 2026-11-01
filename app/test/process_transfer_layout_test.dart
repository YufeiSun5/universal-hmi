// Exercise real dialog routes with synthetic transfer responses.
// No real file chooser, backend, imported production data, or product edits.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/platform/process_files.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_test.dart' show TransferTestApi;
import 'process_test.dart' show ScreenApi;

class TracedTransferApi extends TransferTestApi {
  TracedTransferApi({super.decoded});
  final calls = <Json>[];
  final screenApi = ScreenApi();
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    calls.add({
      'method': method,
      'path': path,
      if (body != null) 'body': jsonDecode(jsonEncode(body)),
    });
    if (path.startsWith('/api/v1/process-transfer/')) {
      return super.request(method, path, body: body, query: query);
    }
    return screenApi.request(method, path, body: body, query: query);
  }

  List<Json> get commits => calls
      .where((r) => r['path'] == '/api/v1/process-transfer/commit')
      .toList();
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

  Future<void> mount(WidgetTester tester, Size size, Widget dialog) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: workspaceTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showDialog<void>(context: context, builder: (_) => dialog);
              },
              child: const Text('打开合成传输'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '打开合成传输');
  }

  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets(
      'partial failure is real commit result and close is not retry $size',
      (tester) async {
        final api = TracedTransferApi();
        var refreshes = 0;
        await mount(
          tester,
          size,
          ProcessTransferDialog(
            api: api,
            stations: const ['站一'],
            pickFile: () async => ProcessFile('synthetic.json', Uint8List(0)),
            onCommitted: () => refreshes++,
          ),
        );
        await tap(tester, '选择文件');
        expect(
          tester.getSize(find.byType(SingleChildScrollView).last).height,
          greaterThanOrEqualTo(64),
        );
        await tap(tester, '按文件站名批量映射，不存在时创建站点');
        final mappingTarget = find.text('画面：泵房画面 · screenA');
        await tester.ensureVisible(mappingTarget);
        await tester.pumpAndSettle();
        expect(mappingTarget.hitTestable(), findsOneWidget);
        final mode = find.text('新建副本').last;
        await tester.ensureVisible(mode);
        await tester.pumpAndSettle();
        expect(mode.hitTestable(), findsOneWidget);

        await tap(tester, '预览');
        final first = jsonEncode(api.lastPreview);
        await tap(tester, '上一步');
        expect(api.commits, isEmpty);
        expect(find.text('确认保存'), findsNothing);
        await tap(tester, '预览');
        expect(jsonEncode(api.lastPreview), first);
        await tap(tester, '确认保存');
        expect(api.commits, hasLength(1));
        expect((api.commits.single['body'] as Map)['preview_token'], 't');
        expect(find.textContaining('已保存'), findsOneWidget);
        expect(find.textContaining('失败'), findsOneWidget);
        await tester.ensureVisible(find.text('剩余 1 项'));
        await tester.pumpAndSettle();
        expect(find.text('剩余 1 项').hitTestable(), findsOneWidget);
        expect(refreshes, 1);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '已完成'))
              .onPressed,
          isNull,
        );
        await tap(tester, '关闭');
        expect(find.byType(ProcessTransferDialog), findsNothing);
        expect(api.commits, hasLength(1));
        expect(refreshes, 1);
      },
    );
    testWidgets(
      'cancel replacement preserves mapping and never commits $size',
      (tester) async {
        final api = TracedTransferApi(
          decoded: {
            'bundle': {
              'screens': [
                {
                  'key': 'screenA',
                  'document': {'station': 'A', 'name': '合成泵房'},
                },
              ],
              'variables': <Json>[],
              'bindings': <Json>[],
              'navigation': {
                'enabled': true,
                'nodes': [
                  {
                    'id': 'g',
                    'label': '区域',
                    'children': [
                      {'id': 'n', 'label': '泵房', 'screen_key': 'screenA'},
                    ],
                  },
                ],
              },
            },
          },
        );
        var refreshes = 0;
        await mount(
          tester,
          size,
          ProcessTransferDialog(
            api: api,
            stations: const ['站一'],
            pickFile: () async =>
                ProcessFile('synthetic-navigation.json', Uint8List(0)),
            onCommitted: () => refreshes++,
          ),
        );
        await tap(tester, '选择文件');
        expect(
          tester.getSize(find.byType(SingleChildScrollView).last).height,
          greaterThanOrEqualTo(64),
        );
        await tap(tester, '按文件站名批量映射，不存在时创建站点');
        await tap(tester, '预览');
        final before = jsonEncode(api.lastPreview);
        await tap(tester, '上一步');
        await tap(tester, '替换现有菜单');
        expect(find.text('替换现有客户端菜单？'), findsOneWidget);
        await tap(tester, '取消');
        await tap(tester, '预览');
        expect(jsonEncode(api.lastPreview), before);
        expect(api.lastPreview!['navigation_target'], {'mode': 'skip'});
        expect(api.commits, isEmpty);
        await tap(tester, '关闭');
        expect(api.commits, isEmpty);
        expect(refreshes, 0);
      },
    );
    testWidgets('file chooser cancellation is read-only $size', (tester) async {
      final api = TracedTransferApi();
      var refreshes = 0;
      await mount(
        tester,
        size,
        ProcessTransferDialog(
          api: api,
          pickFile: () async => null,
          onCommitted: () => refreshes++,
        ),
      );
      await tap(tester, '选择文件');
      expect(find.text('选择工艺资料文件，支持 JSON、XLSX 和 CSV。'), findsOneWidget);
      expect(api.calls.where((c) => c['method'] != 'GET'), isEmpty);
      await tap(tester, '关闭');
      expect(refreshes, 0);
    });
  }
  testWidgets('actual workspace transfer close preserves unsaved document', (
    tester,
  ) async {
    await tester.runAsync(() => processSymbols);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ProcessSession('A')..loaded = true;
    session.controller.add(
      ScreenElement.create('value', const Offset(100, 100)),
    );
    final before = jsonEncode(session.controller.document.toJson());
    expect(session.controller.dirty, isTrue);
    final api = TracedTransferApi();
    var refreshes = 0;
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
            onTransferCommitted: () => refreshes++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('画面文件'));
    await tester.pumpAndSettle();
    await tap(tester, '工艺资料导入 / 导出');
    expect(find.byType(ProcessTransferDialog), findsOneWidget);
    await tap(tester, '关闭');
    expect(jsonEncode(session.controller.document.toJson()), before);
    expect(session.controller.dirty, isTrue);
    expect(api.calls.where((c) => c['method'] != 'GET'), isEmpty);
    expect(refreshes, 0);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
