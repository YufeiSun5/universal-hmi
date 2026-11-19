import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    await tester.pump(const Duration(seconds: 12));
    expect(find.text('9–16 / 19'), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    expect(find.text('17–19 / 19'), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    expect(find.text('1–8 / 19'), findsOneWidget);

    await tester.pump(const Duration(seconds: 12));
    await tester.pumpWidget(panel(6));
    expect(find.text('0:6'), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    expect(find.text('0:6'), findsOneWidget);
  });
}
