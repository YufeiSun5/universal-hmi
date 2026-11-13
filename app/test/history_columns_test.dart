import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/history_columns.dart';
import 'package:universal_hmi/features/external_data/alarm_columns.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/reports.dart';
import 'package:universal_hmi/shared/api.dart';
import 'external_reports_test.dart' show ReportsApi;

class HistoryLayoutApi extends ReportsApi {
  Json screen = {'id': 's', 'kind': 'standard', 'name': '历史查询', 'revision': 1};
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/screens')) {
      if (method == 'GET') {
        return {
          'items': [screen],
        };
      }
      screen = {...body as Json, 'revision': (screen['revision'] as int) + 1};
      return screen;
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'all metadata can be saved hidden while raw zero and missing values remain',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = HistoryLayoutApi();
      // Use the same service for the open report and its column editor.
      final shared = ExternalCatalog(api, canDevelop: true);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportQuery(
              api: api,
              screen: api.screen,
              autoQuery: true,
              actions: [
                HistoryColumnAction(catalog: shared, screen: api.screen),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('质量'), findsNothing);
      expect(find.text('0.00000000'), findsOneWidget);
      await t.tap(find.text('显示列配置'));
      await t.pumpAndSettle();
      final checked = find.byWidgetPredicate(
        (w) => w is Checkbox && w.value == true,
      );
      expect(checked, findsOneWidget);
      await t.tap(checked);
      await t.pump();
      await t.tap(find.text('保存配置'));
      await t.pumpAndSettle();
      expect(
        (api.screen['history_columns'] as List).every(
          (c) => c['visible'] == false,
        ),
        isTrue,
      );
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(find.text('目标时间'), findsNothing);
      expect(find.text('0.00000000'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      api.screen = {
        ...api.screen,
        'revision': 3,
        'history_columns': [
          for (final f in historyFields.entries)
            {
              'key': f.key,
              'label': f.key == 'quality' ? '有效性' : f.value,
              'visible': f.key == 'quality',
            },
        ],
      };
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(find.text('有效性'), findsOneWidget);
      expect(find.text('有效'), findsOneWidget);
      expect(find.text('0.00000000'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      shared.dispose();
    },
  );
  test(
    'allowing hidden metadata does not relax alarm layouts or fixed fields',
    () {
      final hidden = [
        for (final f in historyFields.entries)
          {'key': f.key, 'label': f.value, 'visible': false},
      ];
      expect(
        validateLayout(hidden, fields: historyFields, allowEmpty: true),
        hasLength(4),
      );
      expect(
        () => validateLayout(hidden, fields: historyFields),
        throwsFormatException,
      );
      hidden[1] = hidden[0];
      expect(
        () => validateLayout(hidden, fields: historyFields, allowEmpty: true),
        throwsFormatException,
      );
    },
  );
}
