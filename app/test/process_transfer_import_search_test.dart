import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_pending_result_test.dart';

class ImportSearchApi extends PendingTransferApi {
  static const longName = '长名称合成温度变量用于验证窄窗口不会挤掉映射操作';
  static const north = '来源北站';
  static const south = '来源南站 · 南部管网第二运行分区长站点名称';
  @override
  Future<Json> decodeProcessTransfer(String name, Uint8List bytes) async => {
    'bundle': {
      'format': 'universal-hmi-process-bundle',
      'version': 1,
      'screens': <Json>[],
      'variables': List.generate(
        120,
        (i) => {
          'key': 'Source_KEY_$i',
          'definition': {
            'name': i >= 118 ? longName : '温度$i',
            'station': i < 60
                ? north
                : i == 119
                ? ''
                : south,
          },
        },
      ),
      'bindings': <Json>[
        {
          'screen_key': 'screenA',
          'node_id': 'n1',
          'property': 'point_id',
          'variable_key': 'BindingOnly_Key',
          'operation': 'set',
        },
      ],
    },
  };
}

Future<void> importSearchTap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> openImportSearch(
  WidgetTester tester,
  ImportSearchApi api,
  Size size,
) async {
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
              station: '目标站',
              stations: const ['目标站'],
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await importSearchTap(tester, find.text('打开'));
  await importSearchTap(tester, find.text('选择文件'));
}

Finder importQuery() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == '搜索导入变量',
);
Future<void> queryImports(WidgetTester tester, String value) async {
  await tester.ensureVisible(importQuery());
  await tester.enterText(importQuery(), value);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Finder variableTitle(int i) => find.text(
  '变量：${i >= 118 ? ImportSearchApi.longName : '温度$i'} · Source_KEY_$i',
);

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets(
      'import name, key and file station search with pagination at $size',
      (tester) async {
        final api = ImportSearchApi();
        await openImportSearch(tester, api, size);
        await queryImports(tester, ImportSearchApi.longName);
        expect(variableTitle(118), findsOneWidget);
        expect(find.text('文件来源站点：${ImportSearchApi.south}'), findsOneWidget);
        expect(find.text('文件来源站点：公共'), findsOneWidget);
        expect(variableTitle(119), findsOneWidget);
        expect(variableTitle(0), findsNothing);
        await queryImports(tester, ' source_key_119 ');
        expect(variableTitle(119), findsOneWidget);
        expect(variableTitle(118), findsNothing);
        await queryImports(tester, ImportSearchApi.north);
        expect(variableTitle(0), findsOneWidget);
        expect(variableTitle(50), findsNothing);
        await importSearchTap(tester, find.widgetWithText(TextButton, '下一页'));
        expect(variableTitle(50), findsOneWidget);
        expect(variableTitle(59), findsOneWidget);
        expect(variableTitle(60), findsNothing);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '下一页'))
              .onPressed,
          isNull,
        );
        await queryImports(tester, '公共');
        expect(variableTitle(119), findsOneWidget);
        expect(find.text('变量：BindingOnly_Key'), findsNothing);
        expect(find.text('第 1 页'), findsWidgets);
        await queryImports(tester, '目标站');
        expect(find.text('没有匹配的导入变量'), findsOneWidget);
        await queryImports(tester, 'bindingonly_key');
        expect(find.text('变量：BindingOnly_Key'), findsOneWidget);
        expect(find.text('文件来源站点：公共'), findsNothing);
        await queryImports(tester, '');
        expect(variableTitle(0), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '下一页'))
              .onPressed,
          isNotNull,
        );
        expect(
          find.widgetWithText(FilledButton, '预览').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextButton, '关闭').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'filter and mode changes preserve exact mapped key and full preview request',
    (tester) async {
      final api = ImportSearchApi();
      await openImportSearch(tester, api, const Size(640, 480));
      await queryImports(tester, 'source_key_119');
      final column = find
          .ancestor(of: variableTitle(119), matching: find.byType(Column))
          .first;
      var dropdown = find
          .descendant(of: column, matching: find.byType(DropdownButton<String>))
          .first;
      await importSearchTap(tester, dropdown);
      await importSearchTap(tester, find.text('引用已有').last);
      dropdown = find
          .descendant(of: column, matching: find.byType(DropdownButton<String>))
          .last;
      await importSearchTap(tester, dropdown);
      await importSearchTap(tester, find.text('温度 · 站一').last);
      await queryImports(tester, '来源北站');
      await importSearchTap(tester, find.widgetWithText(ChoiceChip, '导出'));
      await importSearchTap(tester, find.widgetWithText(ChoiceChip, '导入'));
      expect(tester.widget<TextField>(importQuery()).controller!.text, '来源北站');
      await queryImports(tester, 'SOURCE_KEY_119');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find
                  .descendant(
                    of: column,
                    matching: find.byType(DropdownButton<String>),
                  )
                  .last,
            )
            .value,
        'v1',
      );
      await importSearchTap(tester, find.widgetWithText(FilledButton, '预览'));
      final request = api.previewBodies.single;
      expect(request['import_identity'], 'process-transfer-v1');
      expect(request['variable_targets'], {
        'Source_KEY_119': {'mode': 'reference', 'id': 'v1', 'revision': 'abc'},
      });
      expect((request['bundle'] as Map)['variables'], hasLength(120));
      expect(
        ((request['bundle'] as Map)['bindings'] as List).single['variable_key'],
        'BindingOnly_Key',
      );
      expect(request['station_map'], isEmpty);
      expect(api.commitBodies, isEmpty);
    },
  );
}
