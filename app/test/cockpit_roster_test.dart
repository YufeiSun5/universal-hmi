import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/cockpit/charts.dart';
import 'package:universal_hmi/features/cockpit/roster.dart';
import 'package:universal_hmi/features/cockpit/workspace.dart';

Widget wall(int count, {double height = 160}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 260,
      height: height,
      child: CockpitRoster(
        count: count,
        minimumRowHeight: 40,
        buildRow: (index) =>
            Align(alignment: Alignment.centerLeft, child: Text('第 $index 行')),
        buildPanel: (rows, range) => CockpitPanel(
          '站点',
          rows,
          detail: range,
          pinnedHeader: const Text('当前耗热'),
        ),
      ),
    ),
  ),
);

void main() {
  test('heatmap separates no reading, low heat and high heat', () {
    expect(heatmapColor(null, 100), isNot(heatmapColor(0, 100)));
    expect(heatmapColor(30, 100), heatmapPalette[1]);
    expect(heatmapColor(56, 100), heatmapPalette[2]);
    expect(heatmapColor(78, 100), heatmapPalette[3]);
    expect(heatmapColor(100, 100), heatmapPalette.last);
  });

  testWidgets(
    'heatmap wave changes brightness and keeps numeric cells in place',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 190,
              height: 25,
              child: HeatmapWave(
                builder: (phase) => HeatmapCells(
                  values: const [0, 8.4, null],
                  maximum: 10,
                  phase: phase,
                  filledColumns: 2,
                ),
              ),
            ),
          ),
        ),
      );
      final digits = find.text('8.4');
      final position = tester.getCenter(digits);
      final phase = tester
          .widget<HeatmapCells>(find.byType(HeatmapCells))
          .phase;
      final initial = phase.value;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(phase.value, greaterThan(initial));
      expect(tester.getCenter(digits), position);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    },
  );
  testWidgets('scrolls gradually from first to last and back', (tester) async {
    await tester.pumpWidget(wall(4));
    await tester.pump();
    final title = tester.getTopLeft(find.text('站点'));
    final heading = tester.getTopLeft(find.text('当前耗热'));
    final row = find.text('第 0 行');
    final top = tester.getTopLeft(row).dy;
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(find.text('1–2 / 4'), findsOneWidget);

    const step = Duration(milliseconds: 50);
    for (var i = 0; i < 20; i++) {
      await tester.pump(step);
    }
    expect(position.pixels, greaterThan(5));
    expect(tester.getTopLeft(row).dy, lessThan(top));
    expect(tester.getTopLeft(find.text('站点')), title);
    expect(tester.getTopLeft(find.text('当前耗热')), heading);

    var reachedEnd = false, movedBack = false;
    for (var i = 0; i < 350; i++) {
      final previous = position.pixels;
      await tester.pump(step);
      final next = position.pixels;
      expect((next - previous).abs(), lessThan(0.9));
      if (position.maxScrollExtent - next < .01) reachedEnd = true;
      if (reachedEnd && next < previous - .1) {
        movedBack = true;
        break;
      }
    }
    expect(reachedEnd, isTrue);
    expect(movedBack, isTrue);

    for (var i = 0; i < 350 && position.pixels > .01; i++) {
      await tester.pump(step);
    }
    expect(position.pixels, lessThan(.01));
    expect(find.text('1–2 / 4'), findsOneWidget);
  });

  testWidgets('keeps a complete short list still', (tester) async {
    await tester.pumpWidget(wall(2));
    final row = find.text('第 0 行');
    final top = tester.getTopLeft(row);
    await tester.pump(const Duration(seconds: 8));
    expect(tester.getTopLeft(row), top);
    expect(find.byType(Scrollable), findsNothing);
    expect(find.text('第 1 行'), findsOneWidget);
  });

  testWidgets(
    'starts and stops scrolling when the same rows outgrow the viewport',
    (tester) async {
      await tester.pumpWidget(wall(2));
      expect(find.byType(Scrollable), findsNothing);

      await tester.pumpWidget(wall(2, height: 120));
      await tester.pump();
      expect(find.text('1–1 / 2'), findsOneWidget);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final endRange = find.text('2–2 / 2');
      for (
        var i = 0;
        i < 140 && position.maxScrollExtent - position.pixels > .01;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(position.pixels, closeTo(position.maxScrollExtent, .01));
      expect(endRange, findsOneWidget);

      await tester.pumpWidget(wall(2));
      await tester.pump();
      expect(find.byType(Scrollable), findsNothing);
      expect(find.text('2–2 / 2'), findsNothing);
      expect(find.text('第 0 行'), findsOneWidget);
      expect(find.text('第 1 行'), findsOneWidget);
    },
  );

  testWidgets('public cockpit shows data and scrolls with fixed headings', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1879, 935);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final rows = [
      for (var i = 0; i < 16; i++)
        {
          'id': '$i',
          'name': '测试换热站 $i',
          'state': i == 0 ? 'delayed' : 'offline',
          'age': i == 0 ? 242 : 440,
          'value': 90.0 - i,
          'values': [1.0, 2.0],
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CockpitDisplay(
            title: '测试驾驶舱',
            newLayout: false,
            live: {
              'power': 86.4,
              'stations': rows,
              'groups': [
                {...rows.first, 'power': 10.0, 'load_percent': 50.0},
                ...rows.skip(1),
              ],
              'rows': [
                {
                  ...rows.first,
                  'zone': 'first-zone',
                  'power': {'value': 5.0, 'unit': 'MW'},
                },
                ...rows.skip(1),
              ],
            },
            history: {
              'today': {
                'ranking': rows.take(8).toList(),
                'station_hours': {
                  for (final row in rows.take(8)) '${row['id']}': row['values'],
                },
                'closed_hours': 15,
                'partial_hours': [12.0],
                'hour_coverage': [7],
                'heat_station_count': 8,
                'station_count': 16,
                'partial_metrics': {'heat': 3400, 'water': 10.5},
                'metric_coverage': {'heat': 7, 'water': 12},
              },
              'yesterday': {
                'hours': [1.0, 36000.0],
              },
              'rank_names': {'0': '配置中的简称'},
              'rank_per_area': [
                for (final (i, row) in rows.take(8).indexed)
                  {...row, 'value': i == 0 ? .01234 : .009 - i * .001},
              ],
              'week': {
                'labels': ['11-18'],
                'heat': [42.0],
                'partial': {
                  'heat': [true],
                },
              },
              'notice': '部分统计暂未更新',
              'trends': {
                'first-zone': [10.0, null, 15.0],
              },
            },
            weather: const {
              'source': '和风天气',
              'condition': '晴',
              'current': -1.1,
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('今日 GJ/㎡  /  较昨同期至 15:00'), findsOneWidget);
    expect(find.text('0.01234'), findsOneWidget);
    expect(find.text('配置中的简称'), findsNWidgets(2));
    expect(find.text('外部实况 · 晴'), findsOneWidget);
    expect(find.text('天气数据来源：和风天气'), findsOneWidget);
    expect(find.text('和风天气'), findsNothing);
    expect(find.text('今日 00:00–01:00  12.0 GJ'), findsNothing);
    expect(find.text('今日中节能耗热'), findsOneWidget);
    expect(find.text('3,400'), findsWidgets);
    expect(find.text('10.5'), findsWidgets);
    expect(find.textContaining('小计'), findsNothing);
    expect(find.textContaining('缺站'), findsNothing);
    expect(find.text('运行关注'), findsNothing);
    Rect panelRect(String title) => tester.getRect(
      find.ancestor(of: find.text(title), matching: find.byType(CockpitPanel)),
    );
    expect(
      panelRect('天气预报').height,
      greaterThan(2 * panelRect('站点在线状态').height),
    );
    expect(find.text('部分统计暂未更新'), findsNothing);
    expect(find.text('延迟 4分'), findsOneWidget);
    expect(find.text('离线 7分'), findsWidgets);
    expect(find.text('311.0'), findsOneWidget);
    expect(find.text('GJ/h'), findsOneWidget);
    expect(find.text('36.0 GJ/h · 50%'), findsOneWidget);
    expect(find.text('18.0 GJ/h'), findsOneWidget);
    expect(find.text('近2小时热功率（GJ/h）'), findsOneWidget);
    expect(find.textContaining('MW'), findsNothing);
    final trend = tester
        .widgetList<CockpitPlot>(find.byType(CockpitPlot))
        .firstWhere((plot) => !plot.grid);
    expect(trend.values, [36.0, null, 54.0]);
    final hourly = find.ancestor(
      of: find.text('中节能分时耗热'),
      matching: find.byType(CockpitPanel),
    );
    final plot = tester.widget<CockpitPlot>(
      find.descendant(of: hourly, matching: find.byType(CockpitPlot)),
    );
    expect(plot.values, [12]);
    expect(plot.compare, [1, 36000]);
    final strip = tester.getRect(find.byKey(const ValueKey('cockpit-kpis')));
    final indicator = tester.getRect(find.byType(CircularProgressIndicator));
    expect(indicator.top, greaterThan(strip.top + 5));
    expect(indicator.bottom, lessThan(strip.bottom - 5));
    final cardValue = tester.getRect(find.text('0/16'));
    expect(cardValue.bottom, lessThan(strip.bottom - 5));
    final headings = [
      '中节能单位面积耗热排行',
      '站所实时负荷',
      '中节能各站分时耗热',
      '站点在线状态',
      '二次网站区实时工况',
    ];
    final positions = {
      for (final title in headings)
        title: tester
            .state<ScrollableState>(
              find.descendant(
                of: find.ancestor(
                  of: find.text(title),
                  matching: find.byType(CockpitPanel),
                ),
                matching: find.byType(Scrollable),
              ),
            )
            .position,
    };
    Finder panelTitle(String title) => find.descendant(
      of: find.byType(CockpitPanel),
      matching: find.text(title),
    );
    final titleOffsets = {
      for (final title in headings) title: tester.getTopLeft(panelTitle(title)),
    };
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (final title in headings) {
      expect(positions[title]!.pixels, greaterThan(5), reason: title);
      expect(tester.getTopLeft(panelTitle(title)), titleOffsets[title]);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'switches customer and legacy layouts without changing usage data',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1879, 935);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var newLayout = true;
      final row = {
        'id': '01-001',
        'name': '中心站',
        'value': .01234,
        'delta': -3.1,
      };
      final history = <String, dynamic>{
        'today': {
          'date': '2026-11-20',
          'closed_hours': 9,
          'metrics': {'heat': 300, 'electricity': 70, 'water': 30},
          'ranking': [row],
        },
        'unit_rankings': {
          'heat': [row],
          'electricity': [row],
          'water': [row],
        },
        'month': {
          'labels': ['11-18', '11-19'],
          'heat': [500, 400],
          'electricity': [90, 80],
          'water': [50, 40],
        },
        'week': {
          'labels': ['11-18', '11-19'],
          'heat': [500, 400],
        },
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => CockpitDisplay(
                title: '庄河供热运行指挥中心',
                live: const {},
                history: history,
                weather: const {},
                newLayout: newLayout,
                onToggleLayout: () => setState(() => newLayout = !newLayout),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final title in [
        '热单耗排行',
        '电单耗排行',
        '水单耗排行',
        '月度用热曲线',
        '月度用电曲线',
        '月度用水曲线',
        '二次网实时工况',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('-3.1%'), findsNWidgets(3));
      expect(find.text('运行关注'), findsNothing);
      final heat = find.ancestor(
        of: find.text('月度用热曲线'),
        matching: find.byType(CockpitPanel),
      );
      final series = tester.widget<CockpitPlot>(
        find.descendant(of: heat, matching: find.byType(CockpitPlot)),
      );
      expect(series.values, [500, 400, 300]);
      await tester.tap(find.text('切换旧版'));
      await tester.pump();
      expect(find.text('中节能各站分时耗热'), findsOneWidget);
      expect(find.text('近7天用量'), findsOneWidget);
      expect(find.text('运行关注'), findsNothing);
      expect(find.text('月度用热曲线'), findsNothing);
      await tester.tap(find.text('切换新版'));
      await tester.pump();
      expect(find.text('月度用热曲线'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
