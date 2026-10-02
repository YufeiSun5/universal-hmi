import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/trend.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi, launch;

class HistoryWorkflowApi extends FakeApi {
  final historyQueries = <Json>[];
  final seriesQueries = <Json>[];
  final exports = <Json>[];
  Completer<Json>? delayed;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/export') {
      exports.add(Map.of(query ?? {}));
      return {'id': 'job'};
    }
    if (path == '/api/v1/history') {
      historyQueries.add(Map.of(query ?? {}));
      if (delayed != null) {
        final gate = delayed!;
        delayed = null;
        return gate.future;
      }
      return {
        'items': [],
        'stats': {'count': 4000},
        'boundary': 9000,
      };
    }
    if (path == '/api/v1/history/series') {
      seriesQueries.add(Map.of(query ?? {}));
      final ids =
          query?['point_ids']?.toString().split(',') ??
          [query?['point_id']?.toString() ?? 'p0'];
      final from = query?['from'] as int? ?? 1790899200000;
      final to = query?['to'] as int? ?? from + 3600000;
      return {
        'items': [
          for (final id in ids)
            for (final at in [from, to])
              {
                'point_id': id,
                'station': query?['station'] ?? 'IO-01',
                'name': 'Variable $id',
                'unit': '°C',
                'version': 'v1',
                'quality': 'good',
                'value': at == from ? 5 : 95,
                'source_time': DateTime.fromMillisecondsSinceEpoch(
                  at,
                  isUtc: true,
                ).toIso8601String(),
              },
        ],
        'summaries': [
          for (final id in ids)
            {
              'point_id': id,
              'station': 'IO-01',
              'name': 'Variable $id',
              'unit': '°C',
              'version': 'v1',
              'count': 2000,
              'valid': 2000,
              'min': 5,
              'max': 95,
              'mean': 50,
              'latest': 95,
            },
        ],
        'count': 4000,
        'returned': ids.length * 2,
        'sampled': true,
        'before': 9000,
        'boundary': 9000,
        'from': from,
        'to': to,
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'History entry queries automatically; 500-point search uses full-range series',
    (tester) async {
      final api = HistoryWorkflowApi();
      for (var i = 0; i < 500; i++) {
        api.rows.add(api.point('p$i', 'IO-01'));
      }
      await launch(tester, api, size: const Size(1180, 812));
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-7')));
      await tester.pumpAndSettle();
      expect(api.historyQueries.last['station'], 'IO-01');
      expect(api.seriesQueries.last['point_id'], 'p0');
      expect(api.seriesQueries.last['before'], 9000);
      expect(api.seriesQueries.last['max_points'], 600);
      expect(api.seriesQueries.last.containsKey('offset'), isFalse);
      expect(find.text('全范围降采样：4000 原始样本 → 2 绘图点'), findsOneWidget);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<TrendPainter>()
          .single;
      expect(painter.to, api.seriesQueries.last['to']);
      expect(painter.from, api.seriesQueries.last['from']);
      await tester.tap(find.byKey(const Key('history-point-select')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('history-search')), 'p499');
      await tester.pump();
      expect(
        find.byKey(const Key('history-choice-IO-01-p499')),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-choice-IO-01-p499')));
      await tester.tap(find.byKey(const Key('history-choice-apply')));
      await tester.pumpAndSettle();
      expect(api.seriesQueries.last['point_ids'], 'p0,p499');
      expect(find.text('全范围降采样：4000 原始样本 → 4 绘图点'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Curve to report keeps frozen range; dirty filters cannot page or export',
    (tester) async {
      final api = HistoryWorkflowApi();
      api.rows.add(api.point('a', 'IO-01'));
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('nav-7')));
      await tester.pumpAndSettle();
      final frozen = Map<String, dynamic>.of(api.historyQueries.last);
      final calls = api.historyQueries.length;
      await tester.tap(find.text('查看原始样本 / 导出'));
      await tester.pumpAndSettle();
      expect(api.historyQueries.length, calls);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '最小值',
        ),
        '42',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '下一页'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '导出 CSV'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '最小值',
        ),
        '',
      );
      await tester.pump();
      await tester.tap(find.text('导出 CSV'));
      await tester.pumpAndSettle();
      expect(api.exports.single['from'], frozen['from']);
      expect(api.exports.single['to'], frozen['to']);
      expect(api.exports.single['before'], 9000);
      expect(api.exports.single['point_id'], 'a');
      expect(api.exports.single.containsKey('offset'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Invalid manual range cannot issue a query and can be corrected',
    (tester) async {
      final api = HistoryWorkflowApi()
        ..rows.add({
          'id': 'p1',
          'station': 'IO-01',
          'name': 'Variable',
          'unit': '°C',
          'data_type': 'FLOAT',
        });
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('nav-4')));
      await tester.pumpAndSettle();
      final count = api.historyQueries.length;
      await tester.enterText(
        find.byKey(const Key('history-from')),
        '2026-10-03 12:00:00',
      );
      await tester.enterText(
        find.byKey(const Key('history-to')),
        '2026-10-02 12:00:00',
      );
      await tester.tap(find.byKey(const Key('history-query')));
      await tester.pumpAndSettle();
      expect(api.historyQueries.length, count);
      expect(find.textContaining('开始时间不能晚于结束时间'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('history-to')),
        '2026-10-04 12:00:00',
      );
      await tester.tap(find.byKey(const Key('history-query')));
      await tester.pumpAndSettle();
      expect(api.historyQueries.length, count + 1);
      expect(
        api.historyQueries.last['to'],
        DateTime(2026, 10, 4, 12).toUtc().millisecondsSinceEpoch,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('A late history response cannot replace a newer station scope', (
    tester,
  ) async {
    final api = HistoryWorkflowApi();
    api.rows.addAll([api.point('a', 'IO-01'), api.point('b', 'IO-02')]);
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    final gate = Completer<Json>();
    api.delayed = gate;
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('station-IO-02')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    expect(api.historyQueries.last['station'], 'IO-02');
    gate.complete({
      'items': [],
      'stats': {'count': 111},
      'boundary': 111,
    });
    await tester.pumpAndSettle();
    expect(find.text('样本  4000'), findsOneWidget);
    expect(find.text('样本  111'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'Equal source times keep persisted sequence and live input gap order',
    () {
      final rows = <Json>[
        for (var i = 0; i < 60; i++)
          {
            'seq': i,
            'source_time': '2026-10-02T00:00:00Z',
            'value': i,
            'quality': i == 18 ? 'bad' : 'good',
            'break_before': i == 19,
          },
      ];
      final persisted = orderedTrendRows(rows.reversed.toList());
      expect(persisted.map((r) => r['seq']), List.generate(60, (i) => i));
      expect(trendSegments(persisted).map((r) => r.length), [18, 41]);
      final live = rows
          .map((r) => Map<String, dynamic>.of(r)..remove('seq'))
          .toList();
      expect(
        orderedTrendRows(live).map((r) => r['value']),
        List.generate(60, (i) => i),
      );
      expect(trendSegments(orderedTrendRows(live)).map((r) => r.length), [
        18,
        41,
      ]);
    },
  );

  test('Trend breaks invalid, frozen semantic and sampled gaps', () {
    Json row(
      int at, {
      dynamic value = 1,
      String unit = 'C',
      String version = 'v1',
      String quality = 'good',
      bool gap = false,
    }) => {
      'source_time': DateTime.utc(2026, 10, 2, 0, 0, at).toIso8601String(),
      'value': value,
      'unit': unit,
      'version': version,
      'quality': quality,
      'break_before': gap,
    };
    final segments = trendSegments([
      row(0),
      row(1),
      row(2, value: null),
      row(3),
      row(4, quality: 'bad'),
      row(5),
      row(6, unit: 'F'),
      row(7, unit: 'F', version: 'v2'),
      row(8, unit: 'F', version: 'v2', gap: true),
    ]);
    expect(segments.map((s) => s.length), [2, 1, 1, 1, 1, 1]);
    expect(segments.expand((s) => s).every(validTrendSample), isTrue);
  });
}
