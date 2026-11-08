import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/table_csv.dart';
import 'package:universal_hmi/shared/report_style.dart';
import 'package:universal_hmi/features/external_data/custom_report.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/report_designer.dart';
import 'workspace_test.dart' show FakeApi;

class CustomApi extends FakeApi {
  Json? parameters;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    expect(method, 'POST');
    expect(path, '/api/v1/external/screens/custom/query');
    parameters = Map<String, dynamic>.from((body as Map)['parameters']);
    return {
      'report_columns': ['站点', '用量', '缺值'],
      'report_rows': [
        {'站点': '中心站', '用量': '12345678901234567890.12345678', '缺值': null},
      ],
    };
  }
}

void main() {
  testWidgets(
    'saved layout stays resettable when changed SQL schema rejects a query',
    (tester) async {
      final screen = <String, dynamic>{
        'id': 'existing-report',
        'kind': 'custom',
        'revision': 2,
        'report_layouts': {
          'custom': {
            'columns': [
              {'key': '旧热量字段', 'label': '热量 GJ', 'visible': true},
            ],
          },
        },
      };
      final catalog = ExternalCatalog(FakeApi(), canDevelop: true)
        ..screens = [screen];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportStyleHost(
              screen: screen,
              child: ReportStyleAction(catalog: catalog, screen: screen),
            ),
          ),
        ),
      );
      await tester.tap(find.text('报表样式'));
      await tester.pumpAndSettle();
      expect(find.text('旧热量字段'), findsOneWidget);
      expect(find.text('恢复当前表默认'), findsOneWidget);
      expect(find.text('保存样式'), findsOneWidget);
      expect(find.textContaining('请先查询报表'), findsNothing);
      await tester.tap(find.text('恢复当前表默认'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'identical captions in separate metric groups keep distinct values and CSV mapping',
    () {
      final keys = reportColumnKeys(
        ['站点', '用量', '用量'],
        groups: ['', '热量', '电量'],
        groupKeys: ['', 'heat', 'power'],
      );
      final styles = ReportStyles({
        'report_layouts': {
          reportSchemaKey(keys): {
            'columns': [
              {'key': keys[2], 'label': '电用量', 'visible': true},
              {'key': keys[1], 'label': '热用量', 'visible': true},
            ],
          },
        },
      });
      final csv =
          TableCsv(
              styles: styles,
              sourceHeaders: const ['站点', '用量', '用量'],
              headerGroups: const ['', '热量', '电量'],
              headerGroupKeys: const ['', 'heat', 'power'],
            )
            ..add(['站点', '热量 · 用量', '电量 · 用量'])
            ..add(['中心站', '12.50', '0']);
      expect(utf8.decode(csv.bytes), contains('"电量 · 电用量","热量 · 热用量","站点"'));
      expect(utf8.decode(csv.bytes), contains('"0","12.50","中心站"'));
    },
  );
  testWidgets(
    'saved style uses returned column names independent of SQL order and keeps null',
    (tester) async {
      const headers = ['用量', '站点', '缺值'];
      final styles = ReportStyles({
        'kind': 'custom',
        'report_layouts': {
          'custom': {
            'row_height': 40,
            'columns': [
              {'key': '站点', 'label': '热源站', 'visible': true, 'width': 180},
              {
                'key': '用量',
                'label': '热量 GJ',
                'visible': true,
                'decimals': 2,
                'align': 'right',
              },
              {'key': '缺值', 'label': '缺值', 'visible': true},
            ],
          },
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportStyleScope(
              styles: styles,
              child: const DenseTable(
                reportStyle: true,
                headers: headers,
                rows: [
                  ['12345678901234567890.12345678', '中心站', '—'],
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('热源站'), findsOneWidget);
      expect(find.text('热量 GJ'), findsOneWidget);
      expect(find.text('12345678901234567890.12'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('中心站')).dx,
        lessThan(tester.getTopLeft(find.text('12345678901234567890.12')).dx),
      );
      final csv = TableCsv(styles: styles)
        ..add(headers)
        ..add(['12345678901234567890.12345678', '中心站', '—']);
      expect(utf8.decode(csv.bytes), contains('"热源站","热量 GJ","缺值"'));
      expect(
        utf8.decode(csv.bytes),
        contains('"中心站","12345678901234567890.12345678","—"'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('default layout preserves legacy headers and unrounded cell text', () {
    final p = ReportProjection(['统计周期', '站点', '热量（GJ）'], {});
    expect(p.headers, ['统计周期', '站点', '热量（GJ）']);
    expect(p.row(['11月', '中心站', '123.450000']), ['11月', '中心站', '123.450000']);
  });
  test(
    'schema changes append new named fields without assigning old labels to a new column',
    () {
      final p = ReportProjection(
        ['新列', '金额'],
        {
          'columns': [
            {'key': '金额', 'label': '总金额', 'visible': true},
            {'key': '旧列', 'label': '热量', 'visible': true},
          ],
        },
      );
      expect(p.headers, ['总金额', '新列']);
      expect(p.row(['abc', '0']), ['0', 'abc']);
    },
  );
  testWidgets(
    'custom report submits typed form fields and renders returned schema',
    (tester) async {
      final api = CustomApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomReportQuery(
              api: api,
              screen: {
                'id': 'custom',
                'name': '客户月报',
                'procedure': {
                  'schema': 'dbo',
                  'name': '月报',
                  'parameters': [
                    {
                      'name': '月份',
                      'label': '查询月份',
                      'type': 'text',
                      'required': true,
                      'default': '2026-11',
                    },
                  ],
                },
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      expect(api.parameters, {'月份': '2026-11'});
      expect(find.text('中心站'), findsOneWidget);
      expect(find.text('12345678901234567890.12345678'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2026-12');
      await tester.pump();
      expect(find.text('中心站'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
