import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/platform/overview_preferences.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'live_overview_test.dart' show OverviewApi, definitions, live;

class MemoryOverviewPreferences implements OverviewPreferenceStore {
  OverviewPosition position = const OverviewPosition(row: 'b');
  @override
  Future<OverviewPosition> load(String username) async => position;
  @override
  Future<void> save(String username, OverviewPosition value) async {
    position = value;
  }
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'mobile report readable complete values and table toggle at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DenseTable(
                reportStyle: true,
                headers: const [
                  '站点',
                  '时间',
                  '热量',
                  '水量',
                  '报警描述',
                  '电量',
                  '恢复时间',
                  '确认人',
                ],
                rows: const [
                  [
                    '第一站',
                    '2026-11-11 12:00:00',
                    '1234567890.1234',
                    '0',
                    '一段很长的报警描述需要完整阅读不能截断',
                    '—',
                    '2026-11-11 13:00:00',
                    '操作员',
                  ],
                ],
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('mobile-report-records')), findsOneWidget);
        expect(find.text('1234567890.1234'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('mobile-report-expand-0')));
        await tester.pumpAndSettle();
        expect(find.text('一段很长的报警描述需要完整阅读不能截断'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('mobile-report-view-toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dense-table-scroll')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Android overview restores native row and persists on switch/remount',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prefs = MemoryOverviewPreferences();
      final api = OverviewApi();
      Widget view() => MaterialApp(
        home: Scaffold(
          body: LiveOverview(
            api: api,
            definitions: definitions,
            live: live,
            online: true,
            androidClient: true,
            preferenceUsername: 'viewer',
            preferenceStore: prefs,
          ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('overview-station-b')),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('第一站 / 一区').last);
      await tester.pumpAndSettle();
      expect(prefs.position.row, 'a');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('overview-station-a')),
        findsOneWidget,
      );
      expect(api.saveCount, 0);
      await tester.pumpWidget(const SizedBox());
      prefs.position = const OverviewPosition(row: 'not-authorized');
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('overview-station-a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
