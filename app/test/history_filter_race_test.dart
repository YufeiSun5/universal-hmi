import 'dart:async';
import 'dart:typed_data';

// Exercise file_selector's federated testing seam without changing dependencies.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';

import 'workspace_test.dart' show FakeApi, launch;

class MemoryFileSelector extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile.fromData(
    Uint8List.fromList('time,value\n2026-10-01T00:00:00Z,20\n'.codeUnits),
    name: 'data.csv',
  );
}

class DeferredHistoryApi extends FakeApi {
  final commit = Completer<Json>();
  final directory = Completer<void>();
  Completer<void>? historyGate;
  final historyQueries = <Json>[];
  bool imported = false;

  @override
  Future<Json> upload(String name, Uint8List bytes) async {
    return {
      'session_id': 'import-session',
      'sheets': [
        {
          'name': 'data',
          'preview': [
            ['time', 'value'],
            ['2026-10-01T00:00:00Z', '20'],
          ],
        },
      ],
    };
  }

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/import/preview') {
      return {'count': 3, 'rows': [], 'errors': []};
    }
    if (path == '/api/v1/import/commit') {
      final result = await commit.future;
      imported = true;
      return result;
    }
    if (path == '/api/v1/history/catalog' && imported) {
      await directory.future;
      return {
        'items': [
          {'id': 'imported', 'station': '导入数据', 'name': '分析数据'},
        ],
      };
    }
    if (path == '/api/v1/history') {
      final frozen = Map<String, dynamic>.from(query ?? {});
      historyQueries.add(frozen);
      await historyGate?.future;
      final lower = double.tryParse('${frozen['min']}');
      final upper = double.tryParse('${frozen['max']}');
      final values = [20, 40, 60].where(
        (v) => (lower == null || v >= lower) && (upper == null || v <= upper),
      );
      return {
        'items': [],
        'stats': {'count': values.length},
        'boundary': 1,
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

Finder filterField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void expectFiltersEnabled(WidgetTester tester, bool enabled) {
  for (final label in ['最小值', '最大值', '开始时间 ISO（可选）', '结束时间 ISO（可选）']) {
    expect(
      tester.widget<TextField>(filterField(label)).enabled != false,
      enabled,
      reason: '$label must use the completed history scope',
    );
  }
  expect(
    tester
            .widget<OutlinedButton>(
              find.byKey(const Key('history-point-select')),
            )
            .onPressed !=
        null,
    enabled,
  );
  expect(
    tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged !=
        null,
    enabled,
  );
  expect(
    tester
            .widget<TextButton>(find.widgetWithText(TextButton, '清除'))
            .onPressed !=
        null,
    enabled,
  );
}

void main() {
  testWidgets(
    'Import scope restoration cannot overwrite editable history filters',
    (tester) async {
      final api = DeferredHistoryApi();
      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = MemoryFileSelector();
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('nav-4')));
      await tester.pumpAndSettle();
      await tester.enterText(filterField('最小值'), '10');
      await tester.enterText(filterField('最大值'), '90');
      await tester.tap(find.text('导入 Excel / CSV'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('验证映射并预览'));
      await tester.pump();
      await tester.tap(find.text('导入历史数据'));
      await tester.pump();

      // Commit resolves, but directory and initial history reads remain pending.
      // This is the visible report window in which the Web input was lost.
      api.commit.complete({'point_id': 'imported', 'station': '导入数据'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('工作表与列映射'), findsNothing);
      expectFiltersEnabled(tester, false);
      expect(
        tester.widget<TextField>(filterField('最小值')).controller!.text,
        isEmpty,
      );
      api.historyGate = Completer<void>();
      api.directory.complete();
      await tester.pump();
      expect(api.historyQueries.single['station'], '导入数据');
      expectFiltersEnabled(tester, false);
      api.historyGate!.complete();
      await tester.pumpAndSettle();
      expectFiltersEnabled(tester, true);

      await tester.enterText(filterField('最小值'), '30');
      await tester.enterText(filterField('最大值'), '70');
      api.historyGate = Completer<void>();
      await tester.tap(find.text('筛选'));
      await tester.pump();
      expectFiltersEnabled(tester, false);
      expect(api.historyQueries.last, containsPair('min', '30'));
      expect(api.historyQueries.last, containsPair('max', '70'));
      expect(api.historyQueries.last, containsPair('point_id', 'imported'));
      api.historyGate!.complete();
      await tester.pumpAndSettle();
      expectFiltersEnabled(tester, true);
      expect(
        tester.widget<TextField>(filterField('最小值')).controller!.text,
        '30',
      );
      expect(
        tester.widget<TextField>(filterField('最大值')).controller!.text,
        '70',
      );
      expect(find.text('样本  2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Failed history requests unlock filters and preserve entered range',
    (tester) async {
      final api = DeferredHistoryApi();
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('nav-4')));
      await tester.pumpAndSettle();
      await tester.enterText(filterField('最小值'), '30');
      await tester.enterText(filterField('最大值'), '70');
      await tester.enterText(
        filterField('开始时间 ISO（可选）'),
        '2026-10-01T00:00:00Z',
      );
      await tester.enterText(
        filterField('结束时间 ISO（可选）'),
        '2026-10-02T00:00:00Z',
      );
      api.historyGate = Completer<void>();
      await tester.tap(find.text('筛选'));
      await tester.pump();
      expectFiltersEnabled(tester, false);
      api.historyGate!.completeError(
        Exception('history temporarily unavailable'),
      );
      await tester.pumpAndSettle();
      expectFiltersEnabled(tester, true);
      expect(
        tester.widget<TextField>(filterField('最小值')).controller!.text,
        '30',
      );
      expect(
        tester.widget<TextField>(filterField('最大值')).controller!.text,
        '70',
      );
      expect(
        tester.widget<TextField>(filterField('开始时间 ISO（可选）')).controller!.text,
        '2026-10-01T00:00:00Z',
      );
      expect(
        tester.widget<TextField>(filterField('结束时间 ISO（可选）')).controller!.text,
        '2026-10-02T00:00:00Z',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
