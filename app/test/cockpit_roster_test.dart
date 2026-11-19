import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/cockpit/charts.dart';
import 'package:universal_hmi/features/cockpit/roster.dart';

Widget wall(int count) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 260,
      height: 160,
      child: CockpitRoster(
        count: count,
        visibleRows: 2,
        buildRow: (index) =>
            Align(alignment: Alignment.centerLeft, child: Text('第 $index 行')),
        buildPanel: (rows, range) => CockpitPanel(
          '站点',
          rows,
          detail: range == null ? null : Text(range),
          pinnedHeader: const Text('当前耗热'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('scrolls gradually from first to last and back', (tester) async {
    await tester.pumpWidget(wall(4));
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
}
