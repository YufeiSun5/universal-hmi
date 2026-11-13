import 'dart:convert';
import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/report_designer.dart';
import 'package:universal_hmi/shared/report_style.dart';
import 'package:universal_hmi/shared/report_style_transfer.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/table_csv.dart';
import 'energy_statistics_test.dart' show EnergyApi, energy;

class StyleFiles extends FileSelectorPlatform {
  StyleFiles(this.path);
  final String path;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => FileSaveLocation(path);
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(path);
}

void main() {
  test('style transfer rejects mismatches and malformed fields atomically', () {
    final layout = {
      'columns': [
        {'key': 'a', 'label': '用量', 'visible': true},
        {'key': 'b', 'label': '时间', 'visible': true},
      ],
      'group_labels': {'source:heat': '供热'},
      'row_height': 36,
    };
    String encode(Object value, {String table = 'statistics_current'}) =>
        jsonEncode({
          'format': reportStyleFormat,
          'version': 1,
          'screen_kind': 'energy',
          'table_key': table,
          'layout': value,
        });
    decode(String s) => decodeReportStyle(
      s,
      table: 'statistics_current',
      kind: 'energy',
      fields: ['a', 'b'],
    );
    expect(decode(encode(layout)), layout);
    for (final value in [
      {
        ...layout,
        'columns': [
          {'key': 'a', 'label': 'A', 'visible': true},
        ],
      },
      {
        ...layout,
        'columns': [
          {'key': 'a', 'label': 'A', 'visible': true},
          {'key': 'a', 'label': 'B', 'visible': true},
        ],
      },
      {
        ...layout,
        'columns': [
          {'key': 'a', 'label': 'A', 'visible': false},
          {'key': 'b', 'label': 'B', 'visible': false},
        ],
      },
      {...layout, 'row_height': 100},
      {
        ...layout,
        'group_labels': {'source:heat': ''},
      },
      {...layout, 'header_color': 'red'},
    ]) {
      expect(() => decode(encode(value)), throwsFormatException);
    }
    expect(() => decode(encode(layout, table: 'other')), throwsFormatException);
  });

  test('group aliases preserve source identity and exact CSV values', () {
    final layout = {
      'group_labels': {'source:h1': '同名', 'source:h2': '同名'},
      'columns': [
        {'key': 'b', 'label': '第二列', 'visible': true},
        {'key': 'a', 'label': '第一列', 'visible': true},
      ],
    };
    final projection = ReportProjection(['a', 'b'], layout);
    final groups = projection.headerGroups(
      groups: ['热量一', '热量二'],
      groupKeys: ['h1', 'h2'],
    );
    expect(groups.map((g) => g.label), ['同名', '同名']);
    expect(groups.map((g) => g.key), ['source:h2', 'source:h1']);
    final csv =
        TableCsv(
            styles: ReportStyles({
              'report_layouts': {'t': layout},
            }),
            reportTableKey: 't',
            columnKeys: ['a', 'b'],
            sourceHeaders: ['A', 'B'],
            headerGroups: ['热量一', '热量二'],
            headerGroupKeys: ['h1', 'h2'],
          )
          ..add(['A', 'B'])
          ..add(['12345678901234567890.123456', '0']);
    expect(utf8.decode(csv.bytes), contains('"同名 · 第二列","同名 · 第一列"'));
    expect(
      utf8.decode(csv.bytes),
      contains('"0","12345678901234567890.123456"'),
    );
  });

  testWidgets(
    '63 columns stay compact; aliases and JSON draft survive save and reopen',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('report-style-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/style.json');
      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = StyleFiles(file.path);
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);
      final api = EnergyApi();
      final catalog = ExternalCatalog(api, canDevelop: true)
        ..screens = [energy];
      var screen = Map<String, dynamic>.from(energy);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ReportStyleHost(
                screen: screen,
                child: Column(
                  children: [
                    ReportStyleAction(
                      catalog: catalog,
                      screen: screen,
                      onSaved: (s) => update(() => screen = s),
                    ),
                    Expanded(
                      child: DenseTable(
                        headers: [for (var i = 0; i < 63; i++) '数值$i'],
                        columnKeys: [for (var i = 0; i < 63; i++) 'k$i'],
                        reportTableKey: 'statistics_current',
                        headerGroups: List.filled(63, '原上层'),
                        headerGroupKeys: List.filled(63, 'metric'),
                        rows: [List.filled(63, '12.34567')],
                        reportStyle: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      final listRect = t.getRect(
        find.byKey(const ValueKey('result-column-list')),
      );
      expect(listRect.height, greaterThanOrEqualTo(13 * 44));
      expect(t.getRect(find.byKey(const ValueKey('1-k0'))).height, 44);
      await t.tap(find.text('上层标题'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('1-group-label-source:metric')),
        '本期供热',
      );
      await t.tap(find.text('导出 JSON'));
      for (var n = 0; n < 50; n++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
        if (find.text('处理中…').evaluate().isEmpty) break;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pumpAndSettle();
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(data['layout']['group_labels']['source:metric'], '本期供热');
      data['layout']['group_labels']['source:metric'] = 'AI修改上层';
      data['layout']['columns'][0]['label'] = 'AI修改下层';
      file.writeAsStringSync(jsonEncode(data));
      await t.tap(find.text('导入 JSON'));
      for (var n = 0; n < 50; n++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
        if (find.text('处理中…').evaluate().isEmpty) break;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(
        api.savedScreen['report_layouts'],
        isNull,
        reason: 'import is a draft',
      );
      expect(
        find.textContaining('已导入'),
        findsOneWidget,
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((x) => x.data)
            .join(' | '),
      );
      await t.tap(find.text('保存样式'));
      await t.pumpAndSettle();
      expect(
        api.savedScreen['report_layouts']['statistics_current']['group_labels']['source:metric'],
        'AI修改上层',
      );
      final table = t.widget<DenseTable>(find.byType(DenseTable).last);
      expect(table.headers.first, 'AI修改下层');
      expect(table.headerGroups!.first, 'AI修改上层');
      await t.tap(find.text('报表样式'));
      await t.pumpAndSettle();
      await t.tap(find.text('上层标题'));
      await t.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('AI修改上层')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
