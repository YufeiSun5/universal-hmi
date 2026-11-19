import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/cockpit/charts.dart';
import 'package:universal_hmi/features/cockpit/pages.dart';

void main() {
  testWidgets('shows the full roster across pages and returns to the first', (
    tester,
  ) async {
    Widget panel(int count) => MaterialApp(
      home: Scaffold(
        body: CockpitPages(
          count: count,
          pageSize: 8,
          buildPage: (first, last, range) => Text(range ?? '$first:$last'),
        ),
      ),
    );

    await tester.pumpWidget(panel(19));
    expect(find.text('1–8 / 19'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('9–16 / 19'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('17–19 / 19'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('1–8 / 19'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pumpWidget(panel(6));
    expect(find.text('0:6'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('0:6'), findsOneWidget);
  });

  testWidgets(
    'the new rows scroll up while the title and headings stay fixed',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 160,
              child: CockpitPages(
                count: 4,
                pageSize: 2,
                buildPage: (first, last, range) => CockpitPanel(
                  '站点',
                  Align(
                    alignment: Alignment.topLeft,
                    child: Text('第 $first 行'),
                  ),
                  pageStart: first,
                  pinnedHeader: const Text('当前耗热'),
                ),
              ),
            ),
          ),
        ),
      );
      final title = tester.getTopLeft(find.text('站点'));
      final heading = tester.getTopLeft(find.text('当前耗热'));
      final old = find.text('第 0 行');
      final next = find.text('第 2 行');
      final rowTop = tester.getTopLeft(old).dy;

      await tester.pump(const Duration(seconds: 8));
      final enteringY = tester.getTopLeft(next).dy;
      expect(enteringY, greaterThan(rowTop));

      await tester.pump(const Duration(milliseconds: 550));
      expect(tester.getTopLeft(old).dy, lessThan(rowTop));
      expect(tester.getTopLeft(next).dy, lessThan(enteringY));
      expect(tester.getTopLeft(next).dy, greaterThan(rowTop));
      expect(tester.getTopLeft(find.text('站点')), title);
      expect(tester.getTopLeft(find.text('当前耗热')), heading);

      await tester.pumpAndSettle();
      expect(old, findsNothing);
      expect(tester.getTopLeft(next).dy, rowTop);
    },
  );
}
