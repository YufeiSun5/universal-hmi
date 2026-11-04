import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/reports.dart';
import 'package:universal_hmi/shared/api.dart';
import 'external_data_test.dart' show ExternalApi;

class ReportsApi extends ExternalApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/live-overview')) {
      return {
        'rows': [
          {'station': '外部A区', 'site': '中心所', 'name': '中心换热站', 'area': '一区'},
        ],
      };
    }
    if (path.endsWith('/screens')) {
      return {
        'items': [
          {'id': 'alarm', 'name': '报警历史', 'kind': 'alarm', 'revision': 1},
        ],
      };
    }
    if (path.endsWith('/alarm/query')) {
      bodies.add(body as Json);
      return {
        'events': [
          {
            'event_time': '2026-11-02 07:49:17',
            'alarm_time': '2026-11-02 07:49:08',
            'event_type': '报警恢复',
            'resume_value': '0',
          },
        ],
        'has_more': false,
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'standard uses a concrete station, interval and dynamic quality-aware columns',
    (tester) async {
      final api = ReportsApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportQuery(
              api: api,
              screen: const {'kind': 'standard', 'name': '标准历史查询', 'id': 's'},
              autoQuery: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.bodies.single['station'], 'A');
      expect(api.bodies.single['interval'], 5);
      expect(find.text('0.00000000'), findsOneWidget);
      expect(find.text('缺测'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(TextField, '开始时间'), findsOneWidget);
      expect(find.byTooltip('选择开始时间'), findsOneWidget);
      expect(find.text('中心换热站'), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextFormField, '间隔（分钟）'),
        '15',
      );
      await tester.ensureVisible(find.text('查询'));
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      expect(api.bodies.last['interval'], 15);
      expect(api.bodies.last['offset'], 0);
    },
  );
  testWidgets(
    'alarm module opens authorized screen and preserves alarm and recovery times',
    (tester) async {
      final api = ReportsApi(),
          catalog = ExternalCatalog(api, canDevelop: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlarmWorkspace(catalog: catalog)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026-11-02 07:49:17'), findsOneWidget);
      expect(find.text('2026-11-02 07:49:08'), findsOneWidget);
      expect(find.text('报警恢复'), findsOneWidget);
      expect(api.calls.where((s) => s.endsWith('/stations')), isEmpty);
    },
  );
}
