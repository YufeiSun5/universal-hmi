import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_hmi/features/trend.dart';
import 'package:universal_hmi/features/variable_matrix.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '15,000 live KIO points: native profile and pause recovery',
    (tester) async {
      // The profile binding deliberately defaults this to false. Register before
      // enterText; otherwise profile/release sends edits to text client -1.
      tester.testTextInput.register();
      const base = String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://127.0.0.1:18080',
      );
      const control = String.fromEnvironment(
        'HMI_FIXTURE_URL',
        defaultValue: 'http://127.0.0.1:18980',
      );
      const seconds = int.fromEnvironment(
        'HMI_PROFILE_SECONDS',
        defaultValue: 120,
      );
      const preflightOnly = bool.fromEnvironment('HMI_PREFLIGHT_ONLY');
      expect(
        kProfileMode,
        isTrue,
        reason: 'This acceptance is a real profile build',
      );
      expect(seconds, greaterThanOrEqualTo(120));
      final api = PlatformClient(Uri.parse(base));
      final frames = <FrameTiming>[];
      final evidence = <String, dynamic>{
        'required_seconds': seconds,
        'preflight_cycles': 0,
        'checks': <String, bool>{},
        'mode': 'profile',
        'full_acceptance': false,
        'viewport_physical': [
          tester.view.physicalSize.width,
          tester.view.physicalSize.height,
        ],
        'device_pixel_ratio': tester.view.devicePixelRatio,
        'operation_settle_policy':
            'Action completion plus pumpAndSettle at16ms increments; target availability is checked before timing, timeout5s; sampling waits are excluded',
      };
      final checks = evidence['checks'] as Map<String, bool>;
      var collectingFrames = false;
      var phaseName = 'preflight';
      var overviewFaultsActive = false;
      final operations = <Map<String, dynamic>>[];
      final matrixViewportEvidence = <Map<String, dynamic>>[];
      final knownPointIds = <String>{};
      final pointStations = <String, String>{};
      final firstPointIds = <String, String>{};
      void onTimings(List<FrameTiming> timings) {
        if (collectingFrames) frames.addAll(timings);
      }

      SchedulerBinding.instance.addTimingsCallback(onTimings);
      final observedValues = <String>{};
      final sourceAges = <double>[];
      final sourceTimes = <String>{};
      final elapsed = Stopwatch();

      Future<void> tick([int milliseconds = 400]) async {
        await tester.pump(Duration(milliseconds: milliseconds));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      Future<void> waitUntil(bool Function() predicate, String reason) async {
        for (var n = 0; n < 80; n++) {
          if (predicate()) return;
          await tick(250);
        }
        fail('Timed out: $reason');
      }

      Future<void> settleAction() async {
        await tester.pump();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 16),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        expect(tester.takeException(), isNull);
      }

      Future<void> timed(String name, Future<void> Function() action) async {
        final watch = Stopwatch()..start();
        var completed = false;
        evidence['current_action'] = '$phaseName/$name';
        debugPrint('HMI_ACTION start phase=$phaseName action=$name');
        try {
          await action();
          await settleAction();
          completed = true;
        } finally {
          final milliseconds = watch.elapsedMicroseconds / 1000;
          operations.add({
            'action': name,
            'phase': phaseName,
            'wall_ms': milliseconds,
            'status': completed ? 'passed' : 'failed',
          });
          debugPrint(
            'HMI_ACTION end phase=$phaseName action=$name status=${completed ? 'passed' : 'failed'} wall_ms=$milliseconds',
          );
        }
      }

      Future<Json> fixture(String method, String path) async {
        debugPrint('HMI_FIXTURE phase=$phaseName method=$method path=$path');
        final client = HttpClient();
        try {
          final request = await client.openUrl(
            method,
            Uri.parse('$control$path'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          return Map<String, dynamic>.from(
            jsonDecode(await response.transform(utf8.decoder).join()) as Map,
          );
        } finally {
          client.close(force: true);
        }
      }

      Future<void> tapKey(String key) async {
        final finder = find.byKey(Key(key));
        evidence['current_action'] = '$phaseName/wait_for/$key';
        debugPrint('HMI_WAIT phase=$phaseName target=$key');
        if (finder.evaluate().isNotEmpty &&
            finder.hitTestable().evaluate().isEmpty) {
          await tester.ensureVisible(finder);
          await settleAction();
        }
        await waitUntil(() => finder.hitTestable().evaluate().isNotEmpty, key);
        await timed('tap/$key', () => tester.tap(finder.hitTestable()));
      }

      Future<void> context(String station) async {
        final target = find.byKey(Key('station-$station'));
        // A hittable tree item must not be ensureVisible'd: doing that scrolls
        // another station out of a lazy tree during context restoration.
        if (target.hitTestable().evaluate().isEmpty) {
          final tree = find.descendant(
            of: find.byKey(const Key('station-tree-scroll')),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(target, 350, scrollable: tree.first);
        }
        await tapKey('station-$station');
      }

      Future<void> filter(String text) async {
        final search = find.byKey(const Key('point-search'));
        if (search.hitTestable().evaluate().isEmpty) {
          await tester.ensureVisible(search);
          await settleAction();
        }
        await timed(
          'filter/${text.isEmpty ? 'clear' : text}',
          () => tester.enterText(search, text),
        );
        // The debug logical->physical map is stripped from profile builds.
        await tester.sendKeyEvent(
          LogicalKeyboardKey.escape,
          physicalKey: PhysicalKeyboardKey.escape,
        );
      }

      Future<void> showAllVariables() async {
        await tapKey('operational-all');
        final sourceControl = find.byTooltip('按采集来源筛选');
        if (sourceControl.hitTestable().evaluate().isEmpty) {
          await tester.ensureVisible(sourceControl);
          await settleAction();
        }
        await timed('source/select_all', () async {
          await tester.tap(sourceControl.hitTestable());
          await settleAction();
          await tester.tap(
            find.byWidgetPredicate(
              (widget) => widget is PopupMenuItem<String> && widget.value == '',
            ),
          );
        });
        await filter('');
      }

      Future<void> setMonitorLayout(String layout) async {
        await tapKey('monitor-layout-$layout');
        expect(
          find.byType(VariableMatrix),
          layout == 'matrix' ? findsOneWidget : findsNothing,
        );
      }

      Future<void> setMatrixDensity(bool compact) async {
        await tapKey('matrix-density-control');
        await tapKey('matrix-density-${compact ? 'compact' : 'comfortable'}');
        expect(
          tester.widget<VariableMatrix>(find.byType(VariableMatrix)).compact,
          compact,
        );
      }

      Future<void> showTrend() async {
        if (find.byType(Trend).evaluate().isEmpty) {
          final toggle = find.byTooltip('展开实时曲线');
          if (toggle.hitTestable().evaluate().isEmpty) {
            await tester.ensureVisible(toggle);
          }
          await timed('curve/expand', () => tester.tap(toggle));
        }
        expect(find.byType(Trend), findsOneWidget);
      }

      String fieldText(String key) {
        final finder = find.byKey(Key(key));
        if (finder.evaluate().isEmpty) return '';
        final widget = tester.widget(finder);
        if (widget is Text) {
          return widget.data ?? widget.textSpan?.toPlainText() ?? '';
        }
        if (widget is Icon) return widget.semanticLabel ?? '';
        return find
            .descendant(of: finder, matching: find.byType(Text))
            .evaluate()
            .map((e) => (e.widget as Text).data ?? '')
            .join(' ');
      }

      void assertOverview(String station, int fullPointCount) {
        expect(
          find.byKey(
            Key(station == 'global' ? 'global-overview' : 'station-overview'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widgetList<DenseTable>(find.byType(DenseTable))
              .any(
                (table) =>
                    (table.rowCount ?? table.rows.length) >= fullPointCount,
              ),
          isFalse,
          reason:
              'Overview must summarize scope, not flatten the full variable table',
        );
        final overviewPointId = station == 'global'
            ? firstPointIds.values.first
            : firstPointIds[station];
        expect(find.byKey(Key('point-row-$overviewPointId')), findsNothing);
        final summaryTable = find.byKey(const Key('overview-watch-statistics'));
        if (summaryTable.evaluate().isNotEmpty) {
          final table = tester.widget<DenseTable>(summaryTable);
          expect(table.rowCount ?? table.rows.length, lessThanOrEqualTo(6));
        }
        if (station != 'global') {
          expect(fieldText('overview-scope'), station);
          expect(
            fieldText('overview-variable-count'),
            startsWith('$fullPointCount 变量'),
          );
        }
        checks['overview_separate_from_full_variable_monitor'] = true;
      }

      int monitorCount() {
        final matrices = tester.widgetList<VariableMatrix>(
          find.byType(VariableMatrix),
        );
        if (matrices.isNotEmpty) return matrices.single.itemCount;
        final tables = tester.widgetList<DenseTable>(find.byType(DenseTable));
        expect(tables, hasLength(1));
        return tables.single.rowCount ?? tables.single.rows.length;
      }

      void assertMonitorCount(int count) {
        expect(
          monitorCount(),
          count,
          reason:
              'Variable monitor must expose its complete scoped point count',
        );
      }

      void recordMatrixViewport(String scope, int count, String position) {
        final matrix = tester.widget<VariableMatrix>(
          find.byType(VariableMatrix),
        );
        expect(matrix.itemCount, count);
        final gridFinder = find.byKey(const Key('point-grid-scroll'));
        final grid = tester.widget<GridView>(gridFinder);
        expect(grid.childrenDelegate, isA<SliverChildBuilderDelegate>());
        expect(grid.childrenDelegate.estimatedChildCount, count);
        expect(grid.cacheExtent, 0);
        final layout =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        final viewport = tester.getRect(gridFinder);
        final cells = find.descendant(
          of: gridFinder,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'point-row-',
                ),
          ),
        );
        final ids = cells.evaluate().map((element) {
          return (element.widget.key! as ValueKey<String>).value.substring(10);
        }).toList();
        expect(ids, isNotEmpty);
        expect(ids.toSet().length, ids.length);
        expect(ids.every(knownPointIds.contains), isTrue);
        if (scope == 'global') {
          for (final id in ids) {
            expect(fieldText('matrix-station-$id'), pointStations[id]);
          }
          checks['global_matrix_cells_identify_their_real_station'] = true;
        }
        final intersecting = ids.where((id) {
          return tester
              .getRect(find.byKey(Key('point-row-$id')))
              .overlaps(viewport);
        }).length;
        final cap =
            layout.crossAxisCount *
            ((viewport.height /
                        (layout.mainAxisExtent! + layout.mainAxisSpacing))
                    .ceil() +
                1);
        expect(
          ids.length,
          lessThanOrEqualTo(cap),
          reason: 'Only viewport rows plus the two partial edge rows may exist',
        );
        expect(intersecting, greaterThan(0));
        expect(cells.hitTestable().evaluate(), isNotEmpty);
        if (count >= 500) expect(ids.length, lessThan(count));
        matrixViewportEvidence.add({
          'phase': phaseName,
          'scope': scope,
          'position': position,
          'density': matrix.compact ? 'compact' : 'comfortable',
          'total_real_points': count,
          'lazy_delegate_count': grid.childrenDelegate.estimatedChildCount,
          'mounted_cells': ids.length,
          'viewport_intersecting_cells': intersecting,
          'hit_testable_cells': cells.hitTestable().evaluate().length,
          'mounted_point_ids': ids,
          'viewport_width': viewport.width,
          'viewport_height': viewport.height,
          'columns': layout.crossAxisCount,
          'cell_height': layout.mainAxisExtent,
          'row_spacing': layout.mainAxisSpacing,
          'geometry_bound_cells': cap,
          'cache_extent': grid.cacheExtent,
          'scroll_offset': grid.controller!.offset,
          'max_scroll_extent': grid.controller!.position.maxScrollExtent,
          'builder_type': grid.childrenDelegate.runtimeType.toString(),
        });
        evidence['matrix_virtualization'] = matrixViewportEvidence;
        checks['matrix_creates_only_viewport_cells_from_real_points'] = true;
      }

      Future<void> scrollMonitorToLast(
        String scope,
        int count,
        Json lastPoint, {
        required bool matrix,
      }) async {
        assertMonitorCount(count);
        final scrollable = find
            .descendant(
              of: find.byKey(
                Key(matrix ? 'point-grid-scroll' : 'dense-table-scroll'),
              ),
              matching: find.byType(Scrollable),
            )
            .first;
        final target = find.byKey(Key('point-row-${lastPoint['id']}'));
        await timed(
          '$scope/${matrix ? 'matrix' : 'table'}_scroll_${count}_to_last',
          () => tester.scrollUntilVisible(
            target,
            60000,
            scrollable: scrollable,
            maxScrolls: 20,
            duration: const Duration(milliseconds: 16),
          ),
        );
        expect(target.hitTestable(), findsOneWidget);
        if (matrix) recordMatrixViewport(scope, count, 'last');
      }

      try {
        final points = objects(
          (await api.request('GET', '/api/v1/points'))['items'],
        );
        expect(points.length, 15000);
        knownPointIds.addAll(points.map((point) => point['id'].toString()));
        for (final point in points) {
          pointStations[point['id'].toString()] = point['station'].toString();
          firstPointIds.putIfAbsent(
            point['station'].toString(),
            () => point['id'].toString(),
          );
        }
        expect(points.map((p) => p['station']).toSet().length, 30);
        final stationPoints = points
            .where((p) => p['station'] == 'IO-01')
            .toList();
        expect(stationPoints.length, 500);
        final first = stationPoints.firstWhere((p) => p['name'] == 'Point0001');
        final stationLast = stationPoints.firstWhere(
          (p) => p['name'] == 'Point0500',
        );
        final last = points.lastWhere((p) => p['station'] == 'IO-30');
        await tester.pumpWidget(UniversalHmiApp(api: api));
        await waitUntil(
          () => find.byKey(const Key('station-global')).evaluate().isNotEmpty,
          'workspace populated',
        );
        await waitUntil(
          () => find.byKey(const Key('station-IO-01')).evaluate().isNotEmpty,
          'station directory populated',
        );
        // The overview must summarize the chosen station and preserve explicit
        // watch selections. A monitor table is a separate, reachable task.
        final firstSecond = stationPoints.firstWhere(
          (p) => p['name'] == 'Point0002',
        );
        final otherFirst = points.firstWhere(
          (p) => p['station'] == 'IO-02' && p['name'] == 'Point0001',
        );
        final otherSecond = points.firstWhere(
          (p) => p['station'] == 'IO-02' && p['name'] == 'Point0002',
        );
        Future<void> chooseWatch(Json point, Json excluded) async {
          await tapKey('choose-watched');
          await timed(
            'watch/search',
            () => tester.enterText(
              find.byKey(const Key('watch-search')),
              point['name'].toString(),
            ),
          );
          expect(
            find.byKey(Key('watch-choice-${point['id']}')),
            findsOneWidget,
          );
          expect(
            find.byKey(Key('watch-choice-${excluded['id']}')),
            findsNothing,
          );
          await tapKey('watch-choice-${point['id']}');
          await tapKey('watch-save');
          expect(
            find.byKey(Key('watched-variable-${point['id']}')),
            findsOneWidget,
          );
        }

        await context('IO-01');
        await tapKey('nav-6');
        assertOverview('IO-01', 500);
        await chooseWatch(first, otherFirst);
        await context('IO-02');
        await tapKey('nav-6');
        assertOverview('IO-02', 500);
        expect(
          find.byKey(Key('watched-variable-${first['id']}')),
          findsNothing,
        );
        await chooseWatch(otherSecond, firstSecond);
        await context('IO-01');
        await tapKey('nav-6');
        expect(
          find.byKey(Key('watched-variable-${first['id']}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('watched-variable-${otherSecond['id']}')),
          findsNothing,
        );
        await tapKey('watched-variable-${first['id']}');
        expect(
          find.byKey(Key('write-inspector-${first['id']}')),
          findsOneWidget,
        );
        checks['overview_watches_and_point_entry_are_station_scoped'] = true;

        // Different real-MQTT bad-quality counts prove that overview entries do
        // not silently route to a global or another station's issue list.
        await fixture('POST', '/faults/overview-on');
        overviewFaultsActive = true;
        for (final scope in ['IO-01', 'IO-02']) {
          final issuePoints = scope == 'IO-01'
              ? [first]
              : [otherFirst, otherSecond];
          final excluded = scope == 'IO-01' ? otherFirst : first;
          await context(scope);
          await tapKey('nav-6');
          assertOverview(scope, 500);
          await waitUntil(
            () =>
                fieldText('overview-issue-count') ==
                '质量异常 · ${issuePoints.length}',
            '$scope scoped overview issue count',
          );
          await tapKey('overview-attention-all');
          await waitUntil(
            () => monitorCount() == issuePoints.length,
            '$scope scoped anomaly rows',
          );
          expect(find.byType(VariableMatrix), findsOneWidget);
          expect(
            tester.widget<VariableMatrix>(find.byType(VariableMatrix)).compact,
            isTrue,
            reason: 'A station monitor starts as the compact matrix',
          );
          for (final point in issuePoints) {
            expect(find.byKey(Key('point-row-${point['id']}')), findsOneWidget);
            expect(fieldText('quality-${point['id']}'), '坏质量');
          }
          expect(find.byKey(Key('point-row-${excluded['id']}')), findsNothing);
          await tapKey('point-row-${issuePoints.first['id']}');
          expect(
            find.byKey(Key('write-inspector-${issuePoints.first['id']}')),
            findsOneWidget,
          );
          await tapKey('operational-all');
        }
        await fixture('POST', '/faults/off');
        overviewFaultsActive = false;
        for (final scope in ['IO-02', 'IO-01']) {
          await context(scope);
          await tapKey('nav-6');
          await waitUntil(
            () => fieldText('overview-issue-count') == '质量异常 · 0',
            '$scope quality recovery before steady profiling',
          );
          await tapKey('nav-8');
          await showAllVariables();
          assertMonitorCount(500);
          recordMatrixViewport(scope, 500, 'initial');
        }
        checks['matrix_default_compact_and_scoped_anomaly_entry'] = true;
        checks['overview_anomaly_entries_are_station_scoped'] = true;
        checks['overview_quality_faults_cleared_before_steady'] = true;

        // Repeat real interactions before collecting the sustained profile.
        for (var cycle = 0; cycle < 2; cycle++) {
          await context('global');
          await tapKey('nav-6');
          assertOverview('global', 15000);
          await tapKey('nav-8');
          if (cycle == 0) {
            expect(find.byType(VariableMatrix), findsOneWidget);
            expect(
              tester
                  .widget<VariableMatrix>(find.byType(VariableMatrix))
                  .compact,
              isTrue,
            );
          }
          await setMonitorLayout('matrix');
          await setMatrixDensity(true);
          await showAllVariables();
          assertMonitorCount(15000);
          recordMatrixViewport('global', 15000, 'start');
          expect(find.byKey(Key('point-row-${last['id']}')), findsNothing);
          await scrollMonitorToLast('global', 15000, last, matrix: true);
          checks['matrix_15000_scroll_to_last_real_point'] = true;
          await filter('Point0500');
          assertMonitorCount(30);
          recordMatrixViewport('global', 30, 'search/Point0500');
          expect(find.text('Point0500'), findsWidgets);
          checks['matrix_15000_search_returns_30_station_matches'] = true;
          await setMonitorLayout('table');
          await filter('');
          await scrollMonitorToLast('global', 15000, last, matrix: false);
          checks['all_15000_points_scroll_to_last_row'] = true;
          await filter('Point0500');
          assertMonitorCount(30);
          expect(find.text('Point0500'), findsWidgets);
          checks['all_15000_filter'] = true;
          await context('IO-01');
          await tapKey('nav-8');
          await setMonitorLayout('matrix');
          await setMatrixDensity(true);
          await showAllVariables();
          assertMonitorCount(500);
          recordMatrixViewport('IO-01', 500, 'start');
          expect(
            find.byKey(Key('point-row-${stationLast['id']}')),
            findsNothing,
          );
          await scrollMonitorToLast('IO-01', 500, stationLast, matrix: true);
          checks['matrix_500_scroll_to_last_real_point'] = true;
          await filter('Point0500');
          assertMonitorCount(1);
          expect(
            find.byKey(Key('point-row-${stationLast['id']}')),
            findsOneWidget,
          );
          await context('IO-02');
          await tapKey('nav-8');
          await setMonitorLayout('matrix');
          await setMatrixDensity(false);
          await showAllVariables();
          recordMatrixViewport('IO-02', 500, 'comfortable');
          await filter('Point0002');
          await tapKey('nav-6');
          assertOverview('IO-02', 500);
          await context('IO-01');
          expect(
            tester.widget<VariableMatrix>(find.byType(VariableMatrix)).compact,
            isTrue,
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('point-search')))
                .controller!
                .text,
            'Point0500',
          );
          expect(
            find.byKey(Key('point-row-${stationLast['id']}')),
            findsOneWidget,
          );
          checks['station_context_tab_and_filter_restore'] = true;
          await setMonitorLayout('table');
          assertMonitorCount(1);
          await context('IO-02');
          assertOverview('IO-02', 500);
          await tapKey('nav-8');
          expect(
            tester.widget<VariableMatrix>(find.byType(VariableMatrix)).compact,
            isFalse,
          );
          assertMonitorCount(1);
          expect(
            find.byKey(Key('point-row-${otherSecond['id']}')),
            findsOneWidget,
          );
          expect(fieldText('source-age-${otherSecond['id']}'), isNotEmpty);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('point-search')))
                .controller!
                .text,
            'Point0002',
          );
          await context('IO-01');
          expect(find.byType(VariableMatrix), findsNothing);
          assertMonitorCount(1);
          expect(
            find.byKey(Key('point-row-${stationLast['id']}')),
            findsOneWidget,
          );
          checks['matrix_density_view_and_search_restore_per_station'] = true;
          await filter('');
          await scrollMonitorToLast('IO-01', 500, stationLast, matrix: false);
          checks['station_500_rows_scroll_to_last_row'] = true;
          await setMonitorLayout('matrix');
          expect(
            tester.widget<VariableMatrix>(find.byType(VariableMatrix)).compact,
            isTrue,
          );
          await filter('');
          await tapKey('operational-watched');
          assertMonitorCount(1);
          expect(find.byKey(Key('point-row-${first['id']}')), findsOneWidget);
          expect(
            find.byKey(Key('point-row-${otherSecond['id']}')),
            findsNothing,
          );
          await tapKey('point-row-${first['id']}');
          expect(
            find.byKey(Key('write-inspector-${first['id']}')),
            findsOneWidget,
          );
          expect(fieldText('rw-${first['id']}'), 'R');
          expect(fieldText('quality-${first['id']}'), '正常');
          expect(fieldText('unit-${first['id']}'), 'kPa');
          expect(
            tester
                .widget<FilledButton>(find.byKey(const Key('write-submit')))
                .onPressed,
            isNull,
          );
          checks['matrix_cell_value_unit_quality_rw_and_write_entry'] = true;
          checks['matrix_watch_filter_and_write_entry_are_station_scoped'] =
              true;
          await tapKey('operational-all');
          await filter('Point0001');
          await showTrend();
          final valueKey = 'value-${first['id']}';
          final renderedBefore = fieldText(valueKey);
          expect(
            renderedBefore,
            isNotEmpty,
            reason: 'Actual value cell must be rendered',
          );
          await tick(1500);
          await waitUntil(
            () => fieldText(valueKey) != renderedBefore,
            'rendered value changes',
          );
          checks['rendered_value_changes'] = true;
          evidence['preflight_cycles'] = cycle + 1;
        }
        evidence['operation_latency_ms'] = operations;
        if (preflightOnly) {
          await fixture('POST', '/settle');
          await fixture('POST', '/phase/preflight_complete');
          evidence['status'] = 'preflight_passed_only';
          return;
        }
        await tapKey('nav-8');
        await tick(1500);

        Json observe() {
          final trends = tester.widgetList<Trend>(find.byType(Trend)).toList();
          final renderedSamples =
              trends
                  .expand((t) => t.rows)
                  .where((r) => r['point_id'] == first['id'])
                  .toList()
                ..sort(
                  (a, b) => a['source_time'].toString().compareTo(
                    b['source_time'].toString(),
                  ),
                );
          expect(
            renderedSamples,
            isNotEmpty,
            reason: 'Visible curve contains the real point',
          );
          final current = renderedSamples.last;
          final at = DateTime.parse(current['source_time'].toString());
          final age =
              DateTime.now().toUtc().difference(at.toUtc()).inMilliseconds /
              1000;
          sourceAges.add(age);
          sourceTimes.add(current['source_time'].toString());
          final rendered = fieldText('value-${first['id']}');
          expect(rendered, isNotEmpty);
          observedValues.add(rendered);
          final row = find.byKey(Key('point-row-${first['id']}'));
          final tooltip = tester.widget<Tooltip>(
            find.ancestor(of: row, matching: find.byType(Tooltip)).first,
          );
          expect(
            tooltip.message,
            contains('源时间 ${matrixTime(current['source_time'])}'),
            reason:
                'Compact cell details and actual curve use the same source time',
          );
          final quality = fieldText('quality-${first['id']}');
          expect(quality, isNotEmpty);
          if (trends.any(
            (t) =>
                t.rows.length >= 4 &&
                t.rows.map((r) => r['source_time']).toSet().length >= 2 &&
                t.rows.map((r) => r['value']).toSet().length >= 2,
          )) {
            checks['actual_timestamped_changing_curve_samples'] = true;
          }
          return {
            'age': age,
            'value': rendered,
            'source_time': current['source_time'],
            'row_text': '${fieldText('point-row-${first['id']}')} $quality',
          };
        }

        Future<void> repeatedInteractions() async {
          await context('global');
          await tapKey('nav-8');
          await setMonitorLayout('matrix');
          await showAllVariables();
          await filter('Point0500');
          assertMonitorCount(30);
          await filter('');
          recordMatrixViewport('global', 15000, 'steady/start');
          await scrollMonitorToLast('global', 15000, last, matrix: true);
          await setMonitorLayout('table');
          await scrollMonitorToLast('global', 15000, last, matrix: false);
          await context('IO-02');
          await tapKey('nav-6');
          assertOverview('IO-02', 500);
          await context('IO-01');
          await tapKey('nav-8');
          expect(find.byType(VariableMatrix), findsOneWidget);
          await showTrend();
          await timed(
            'curve/pan',
            () => tester.drag(find.byType(Trend).first, const Offset(-80, 0)),
          );
          await timed(
            'curve/zoom',
            () => tester.sendEventToBinding(
              PointerScrollEvent(
                position: tester.getCenter(find.byType(Trend).first),
                scrollDelta: const Offset(0, -120),
              ),
            ),
          );
        }

        frames.clear();
        phaseName = 'steady';
        await fixture('POST', '/phase/steady');
        collectingFrames = true;
        elapsed.start();
        var nextInteraction = 15;
        var steadyCycles = 0;
        while (elapsed.elapsed.inSeconds < seconds) {
          await tick(500);
          observe();
          if (elapsed.elapsed.inSeconds >= nextInteraction &&
              elapsed.elapsed.inSeconds < seconds - 5) {
            await repeatedInteractions();
            steadyCycles++;
            nextInteraction += 20;
          }
        }
        elapsed.stop();
        collectingFrames = false;
        evidence['measured_seconds'] = elapsed.elapsedMilliseconds / 1000;
        evidence['steady_interaction_cycles'] = steadyCycles;
        expect(evidence['measured_seconds'], greaterThanOrEqualTo(seconds));
        expect(steadyCycles, greaterThanOrEqualTo(4));
        checks['repeated_interactions_during_full_steady_window'] = true;
        expect(frames.length, greaterThan(30));
        evidence['steady_source_age_seconds_max'] = sourceAges.reduce(math.max);
        evidence['steady_source_age_seconds_mean'] =
            sourceAges.reduce((a, b) => a + b) / sourceAges.length;

        phaseName = 'pause';
        await fixture('POST', '/pause');
        await fixture('POST', '/phase/pause');
        final beforePause = observe();
        final pauseWatch = Stopwatch()..start();
        var staleObserved = false;
        while (pauseWatch.elapsedMilliseconds < 10000) {
          await tick(500);
          final state = observe();
          if (state['row_text'].toString().contains('陈旧')) {
            if (!staleObserved) {
              evidence['rendered_stale_after_ms'] =
                  pauseWatch.elapsedMilliseconds;
            }
            staleObserved = true;
          }
        }
        evidence['pause_ms'] = pauseWatch.elapsedMilliseconds;
        expect(
          staleObserved,
          isTrue,
          reason: 'Separate10s pause must render stale state',
        );
        phaseName = 'recovery';
        await fixture('POST', '/phase/recovery');
        await fixture('POST', '/resume');
        final recoveryWatch = Stopwatch()..start();
        Json recovery = {};
        await waitUntil(() {
          recovery = observe();
          return recovery['row_text'].toString().contains('正常') &&
              (recovery['age'] as num) < 4 &&
              recovery['source_time'] != beforePause['source_time'] &&
              recovery['value'] != beforePause['value'];
        }, 'fresh changing rendered value after pause');
        evidence['recovery_actual_ms'] = recoveryWatch.elapsedMilliseconds;
        evidence['recovery_source_age_seconds'] = recovery['age'];
        checks['pause_10s_stale_and_recovery'] = true;
        await fixture('POST', '/settle');
        await fixture('POST', '/phase/complete');
        checks['published_transport_runtime_accounting_exact'] = true;
        expect(checks['actual_timestamped_changing_curve_samples'], isTrue);
        expect(observedValues.length, greaterThan(10));
        expect(sourceTimes.length, greaterThan(10));
        expect(
          objects(
            (await api.request('GET', '/api/v1/runtime'))['values'],
          ).length,
          15000,
        );
        evidence['sampling_source'] =
            'Actual visible compact matrix value and quality cells, cell source-time tooltip, and Trend rows; no extra runtime polling during steady measurement';
        evidence['rendered_value_changes'] = observedValues.length;
        evidence['distinct_source_timestamps'] = sourceTimes.length;
        evidence['source_age_seconds_max'] = sourceAges.reduce(math.max);
        evidence['full_acceptance'] = true;
        evidence['status'] = 'passed';
        double percentile(List<double> values, double fraction) {
          values.sort();
          return values[(fraction * values.length).ceil().clamp(
                1,
                values.length,
              ) -
              1];
        }

        evidence['frames'] = {
          'count': frames.length,
          'build_p99_ms': percentile(
            frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
            .99,
          ),
          'raster_p99_ms': percentile(
            frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList(),
            .99,
          ),
          'total_p99_ms': percentile(
            frames.map((f) => f.totalSpan.inMicroseconds / 1000).toList(),
            .99,
          ),
          'over_16_7ms': frames
              .where((f) => f.totalSpan.inMicroseconds > 16700)
              .length,
        };
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        binding.reportData = evidence;
        evidence['operation_latency_ms'] = operations;
        if (overviewFaultsActive) {
          await fixture('POST', '/faults/off');
        }
        await fixture('POST', '/pause');
        await tester.pumpWidget(const SizedBox());
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
