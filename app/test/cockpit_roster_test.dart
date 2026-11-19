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

  testWidgets('all six overflowing cockpit lists scroll with fixed headings', (
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
          'state': 'offline',
          'value': 90.0 - i,
          'values': [1.0, 2.0],
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CockpitDisplay(
            title: '测试驾驶舱',
            live: {'stations': rows, 'groups': rows, 'rows': rows},
            history: {
              'today': {'ranking': rows, 'closed_hours': 15},
              'zones': {'rows': rows},
            },
            weather: const {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('今日 GJ  /  较昨同期至 15:00'), findsOneWidget);
    final headings = [
      '换热站耗热排行',
      '站所实时负荷',
      '站区分时耗热',
      '站点在线状态',
      '运行关注',
      '站区实时工况',
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
}
