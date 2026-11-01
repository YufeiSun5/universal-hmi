import 'dart:async';
import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_export_feedback_test.dart' show ExportSelector;
import 'process_transfer_test.dart' show TransferTestApi;

String screenName(int i) =>
    '画面${i.toString().padLeft(3, '0')} · 换热机组与补水系统的完整工艺画面';
String screenStation(int i) => i == 0
    ? '公共'
    : i.isEven
    ? '甲站'
    : '乙站';
String variableName(int i) => '变量${i.toString().padLeft(3, '0')}';

class SelectionApi extends TransferTestApi {
  Completer<Uint8List>? pendingExport;
  final exports = <Json>[];
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final result = await super.request(method, path, body: body, query: query);
    if (path.endsWith('/catalog')) {
      return {
        ...result,
        'screens': [
          for (var i = 0; i < 120; i++)
            {
              'id': 'screen-$i',
              'name': screenName(i),
              'station': i == 0 ? '' : screenStation(i),
              'revision': 1,
            },
        ],
      };
    }
    return result;
  }

  @override
  Future<Uint8List> exportProcessTransfer(Json body) async {
    exports.add(Map<String, dynamic>.from(body));
    return pendingExport == null ? Uint8List(0) : await pendingExport!.future;
  }
}

void main() {
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Finder checkbox(String title) => find.widgetWithText(CheckboxListTile, title);
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> query(WidgetTester tester, String label, String text) async {
    await tester.ensureVisible(field(label));
    await tester.pumpAndSettle();
    await tester.enterText(field(label), text);
    await tester.pumpAndSettle();
  }

  String input(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label)).controller!.text;
  Future<void> open(
    WidgetTester tester,
    SelectionApi api,
    Size size, {
    String station = '甲站',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = ExportSelector();
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
                station: station,
                variables: [
                  for (var i = 0; i < 120; i++)
                    {
                      'id': 'variable-$i',
                      'name': variableName(i),
                      'station': i.isEven ? '甲站' : '乙站',
                    },
                ],
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, find.text('打开'));
    await tap(tester, find.widgetWithText(ChoiceChip, '导出'));
  }

  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets(
      'export search and cross-page explicit selections survive hidden rows at $size',
      (tester) async {
        final api = SelectionApi();
        await open(tester, api, size);
        expect(field('搜索导出画面'), findsOneWidget);
        expect(find.text('已选画面 0，显式选择变量 0').hitTestable(), findsOneWidget);
        expect(find.byTooltip('打开时站点：甲站'), findsOneWidget);
        expect(find.text('按勾选项目导出，可跨站。'), findsOneWidget);
        expect(find.textContaining('并非最终导出总数'), findsOneWidget);
        await query(tester, '搜索导出画面', '画面119');
        expect(find.text('匹配画面 1 / 120'), findsOneWidget);
        await tap(tester, checkbox('${screenName(119)} · 乙站'));
        await query(tester, '搜索导出画面', '甲站');
        expect(find.text('匹配画面 59 / 120'), findsOneWidget);
        expect(checkbox('${screenName(119)} · 乙站'), findsNothing);
        await tap(tester, checkbox('${screenName(2)} · 甲站'));
        await query(tester, '搜索导出画面', '不存在的画面');
        expect(find.text('没有匹配画面'), findsOneWidget);
        expect(find.text('匹配画面 0 / 120'), findsOneWidget);
        expect(find.text('已选画面 2，显式选择变量 0').hitTestable(), findsOneWidget);
        await query(tester, '搜索导出画面', '公共');
        expect(checkbox('${screenName(0)} · 公共'), findsOneWidget);
        await query(tester, '搜索导出画面', '');
        expect(
          tester
              .widget<CheckboxListTile>(checkbox('${screenName(119)} · 乙站'))
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<CheckboxListTile>(checkbox('${screenName(2)} · 甲站'))
              .value,
          isTrue,
        );
        await tap(tester, checkbox('${variableName(0)} · 甲站'));
        await tap(tester, find.text('下一页'));
        await tap(tester, checkbox('${variableName(50)} · 甲站'));
        await query(tester, '搜索导出变量', variableName(119));
        await tap(tester, checkbox('${variableName(119)} · 乙站'));
        await query(tester, '搜索导出变量', '');
        expect(
          tester
              .widget<CheckboxListTile>(checkbox('${variableName(0)} · 甲站'))
              .value,
          isTrue,
        );
        await tap(tester, find.text('下一页'));
        expect(
          tester
              .widget<CheckboxListTile>(checkbox('${variableName(50)} · 甲站'))
              .value,
          isTrue,
        );
        await query(tester, '搜索导出变量', variableName(119));
        await query(tester, '搜索导出画面', '画面119');
        await tap(tester, find.widgetWithText(ChoiceChip, '导入'));
        await tap(tester, find.widgetWithText(ChoiceChip, '导出'));
        expect(input(tester, '搜索导出画面'), '画面119');
        expect(input(tester, '搜索导出变量'), variableName(119));
        expect(find.text('已选画面 2，显式选择变量 3').hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byType(SingleChildScrollView).first).height,
          greaterThanOrEqualTo(80),
        );
        await tap(tester, find.widgetWithText(FilledButton, '导出'));
        expect(api.exports, hasLength(1));
        expect(
          api.exports.single['screen_ids'],
          unorderedEquals(['screen-119', 'screen-2']),
        );
        expect(
          api.exports.single['variable_ids'],
          unorderedEquals(['variable-0', 'variable-50', 'variable-119']),
        );
        expect(api.exports.single.containsKey('station'), isFalse);
        expect(find.text('已选画面 2，显式选择变量 3').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'reopening from another station keeps scope explicit without carrying selection',
    (tester) async {
      final api = SelectionApi();
      await open(tester, api, const Size(640, 480));
      await query(tester, '搜索导出画面', '画面119');
      await tap(tester, checkbox('${screenName(119)} · 乙站'));
      await tap(tester, find.text('关闭'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await open(tester, api, const Size(640, 480), station: '乙站');
      expect(find.byTooltip('打开时站点：乙站'), findsOneWidget);
      expect(find.text('按勾选项目导出，可跨站。'), findsOneWidget);
      expect(find.text('已选画面 0，显式选择变量 0'), findsOneWidget);
      expect(input(tester, '搜索导出画面'), '');
      expect(checkbox('${screenName(2)} · 甲站'), findsOneWidget);
      await tap(tester, find.widgetWithText(FilledButton, '导出'));
      expect(api.exports.single['screen_ids'], isEmpty);
      expect(api.exports.single['variable_ids'], isEmpty);
    },
  );
  testWidgets(
    'long opening station stays compact and full name is available in tooltip',
    (tester) async {
      final station = List.filled(8, '甲站供热运行分区').join(' · ');
      await open(
        tester,
        SelectionApi(),
        const Size(420, 360),
        station: station,
      );
      final text = '打开时站点：$station';
      final label = tester.widget<Text>(find.text(text));
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      await tester.longPress(find.byTooltip(text));
      await tester.pumpAndSettle();
      expect(find.text(text), findsNWidgets(2));
      expect(find.text('已选画面 0，显式选择变量 0').hitTestable(), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, '导出').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unspecified opening station is not mislabelled as public screen scope',
    (tester) async {
      await open(tester, SelectionApi(), const Size(640, 480), station: '');
      expect(find.byTooltip('打开时站点：未指定'), findsOneWidget);
      await query(tester, '搜索导出画面', '公共');
      expect(checkbox('${screenName(0)} · 公共'), findsOneWidget);
      expect(find.text('按勾选项目导出，可跨站。'), findsOneWidget);
    },
  );
  testWidgets(
    'pending export selection stays aligned with request until completion',
    (tester) async {
      final gate = Completer<Uint8List>();
      final api = SelectionApi()..pendingExport = gate;
      await open(tester, api, const Size(640, 480));
      await query(tester, '搜索导出画面', '画面119');
      await tap(tester, checkbox('${screenName(119)} · 乙站'));
      await query(tester, '搜索导出变量', variableName(119));
      await tap(tester, checkbox('${variableName(119)} · 乙站'));
      await tap(tester, find.widgetWithText(FilledButton, '导出'));
      await query(tester, '搜索导出画面', '画面118');
      await tap(tester, checkbox('${screenName(118)} · 甲站'));
      await query(tester, '搜索导出变量', variableName(118));
      await tap(tester, checkbox('${variableName(118)} · 甲站'));
      final shared = checkbox('公共实例导出为独立副本（不保留同步关联）');
      await tap(tester, shared);
      expect(tester.widget<CheckboxListTile>(shared).value, isFalse);
      expect(find.text('已选画面 1，显式选择变量 1').hitTestable(), findsOneWidget);
      expect(api.exports, hasLength(1));
      expect(api.exports.single['screen_ids'], ['screen-119']);
      expect(api.exports.single['variable_ids'], ['variable-119']);
      expect(api.exports.single['expand_shared'], isFalse);
      gate.complete(Uint8List(0));
      await tester.pumpAndSettle();
      await tap(tester, checkbox('${screenName(118)} · 甲站'));
      await tap(tester, checkbox('${variableName(118)} · 甲站'));
      expect(find.text('已选画面 2，显式选择变量 2').hitTestable(), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(shared).onChanged, isNotNull);
      expect(api.exports, hasLength(1));
    },
  );
}
