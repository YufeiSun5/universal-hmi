import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/trend.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  testWidgets('Trend viewport and legend scroll restore in independent slots', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    final start = DateTime.utc(2026, 10, 2);
    final rows = <Json>[
      for (var curve = 0; curve < 6; curve++)
        for (var i = 0; i < 20; i++)
          {
            'point_id': 'p$curve',
            'source_time': start.add(Duration(seconds: i)).toIso8601String(),
            'value': i + curve,
            'quality': 'good',
          },
    ];
    Widget frame(String station) => MaterialApp(
      home: Scaffold(
        body: PageStorage(
          bucket: bucket,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              height: 300,
              child: Trend(
                key: PageStorageKey('trend-$station'),
                rows: rows,
                names: {
                  for (var i = 0; i < 6; i++)
                    'p$i': 'A long variable label for curve $i',
                },
              ),
            ),
          ),
        ),
      ),
    );
    int visibleSpan() {
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<TrendPainter>()
          .single;
      return painter.to - painter.from;
    }

    Future<void> zoom() async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(Trend)),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(frame('IO-01'));
    await tester.pumpAndSettle();
    final fullSpan = visibleSpan();
    await zoom();
    final firstStationSpan = visibleSpan();
    expect(firstStationSpan, lessThan(fullSpan));

    await tester.pumpWidget(frame('IO-02'));
    await tester.pumpAndSettle();
    expect(visibleSpan(), fullSpan);
    await zoom();
    await zoom();
    final secondStationSpan = visibleSpan();
    expect(secondStationSpan, lessThan(firstStationSpan));

    for (var round = 0; round < 4; round++) {
      await tester.pumpWidget(frame('IO-01'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(visibleSpan(), firstStationSpan);
      // Persist a real double-valued horizontal scroll offset as well.
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(frame('IO-02'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(visibleSpan(), secondStationSpan);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
