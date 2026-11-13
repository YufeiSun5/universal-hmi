import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/process/monitor.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/features/external_data/comparison.dart';
import 'package:universal_hmi/shared/api.dart';
import 'heating_monitor_test.dart' show MonitorApi;

class EnergyDirectoryApi extends MonitorApi {
  int queries = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/external/screens') {
      return {
        'items': [
          {
            'id': 'energy-main',
            'kind': 'energy',
            'name': '各站水电热',
            'revision': 1,
          },
          {
            'id': 'comparison-main',
            'kind': 'comparison',
            'name': '同期能耗比较',
            'revision': 1,
          },
          {
            'id': 'history-main',
            'kind': 'standard',
            'name': '不属于能耗的历史',
            'revision': 1,
          },
        ],
      };
    }
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'code': 'A', 'name': '合成整站'},
        ],
      };
    }
    if (path.endsWith('/query')) {
      queries++;
      return {'statistics': <Json>[], 'comparisons': <Json>[]};
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      'energy uses directly selectable left directory, preserves query on collapse mobile=$mobile',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1440, 900);
        addTearDown(tester.view.reset);
        final api = EnergyDirectoryApi();
        await tester.pumpWidget(
          MaterialApp(
            home: Workspace(
              api: api,
              canDevelop: false,
              canWrite: false,
              androidClient: mobile,
              initialView: 'runtime',
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester
            .widget<HeatingMonitor>(find.byType(HeatingMonitor))
            .onNavigate(18);
        await tester.pumpAndSettle();
        expect(find.byType(StatisticsQuery), findsOneWidget);
        expect(find.text('各站水电热'), findsOneWidget);
        expect(find.text('同期能耗比较'), findsOneWidget);
        expect(find.text('不属于能耗的历史'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is DropdownButton<String> &&
                const {'energy-main', 'comparison-main'}.contains(w.value),
          ),
          findsNothing,
        );
        await tester.tap(find.text('同期能耗比较'));
        await tester.pumpAndSettle();
        expect(find.byType(ComparisonQuery), findsOneWidget);
        final before = api.queries;
        final sameQuery = tester.element(find.byType(ComparisonQuery));
        if (mobile) {
          await tester.tap(find.byKey(const Key('compact-directory-collapse')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('mobile-directory-restore')));
        } else {
          await tester.tap(find.byTooltip('显示或收起目录'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('显示或收起目录'));
        }
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(ComparisonQuery)), same(sameQuery));
        expect(api.queries, before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
