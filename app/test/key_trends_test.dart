import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/key_trends.dart';
import 'package:universal_hmi/platform/total_report_view.dart';
import 'package:universal_hmi/shared/api.dart';
import 'external_data_test.dart' show ExternalApi, screen;

void main() {
  test(
    'key trends inherit the authorized hourly screen without new grants',
    () {
      final catalog = ExternalCatalog(ExternalApi(), canDevelop: false);
      catalog.screens = [
        screen,
        {...screen, 'id': 'day', 'kind': 'daily'},
      ];
      final curve = catalog.historyScreens.singleWhere(
        (s) => s['kind'] == 'key_trends',
      );
      expect(curve['id'], 'daily/key-trends');
      expect(curve['query_id'], 'daily');
      expect(curve['source_id'], screen['source_id']);
      catalog.screens = [];
      expect(catalog.historyScreens, isEmpty);
      catalog.dispose();
    },
  );

  testWidgets('renderer can query only its hourly screen with fixed mode', (
    t,
  ) async {
    final api = ExternalApi();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeyTrendsWorkspace(
            api: api,
            screen: {...screen, 'id': 'daily/key-trends', 'query_id': 'daily'},
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    final bridge = t
        .widget<TotalReportView>(find.byType(TotalReportView))
        .bridge;
    final replies = <Json>[];
    bridge.send = (v) async {
      replies.add(jsonDecode(v) as Json);
    };
    bridge.receive({'channel': 'hmi-key-trends-v1', 'type': 'ready'});
    bridge.receive({
      'channel': 'hmi-key-trends-v1',
      'type': 'stations',
      'id': 's',
    });
    await t.pump();
    await t.pump();
    expect(api.calls, contains('GET /api/v1/external/screens/daily/stations'));
    bridge.receive({
      'channel': 'hmi-key-trends-v1',
      'type': 'query',
      'id': 'q',
      'from': '2026-11-16',
      'to': '2026-11-16',
      'stations': ['A', 'B'],
      'path': '/api/v1/security/accounts',
      'mode': 'custom',
    });
    await t.pump();
    await t.pump();
    expect(api.calls.last, 'POST /api/v1/external/screens/daily/query');
    expect(api.bodies.last, {
      'mode': 'key_trends',
      'from': '2026-11-16',
      'to': '2026-11-16',
      'stations': ['A', 'B'],
    });
    final count = api.calls.length;
    bridge.receive({
      'channel': 'hmi-total-reports-v1',
      'type': 'query',
      'id': 'wrong',
    });
    bridge.receive({
      'channel': 'hmi-key-trends-v1',
      'type': 'api',
      'id': 'arbitrary',
      'path': '/api/v1/points',
    });
    bridge.receive({
      'channel': 'hmi-key-trends-v1',
      'type': 'query',
      'id': 'bad',
      'from': '2026-11-16',
      'to': '2026-11-16',
      'stations': [],
    });
    await t.pump();
    await t.pump();
    expect(api.calls.length, count);
    expect(replies.last['error'], isNotNull);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('leaving drops late query responses', (t) async {
    final api = ExternalApi()..pending = Completer<Json>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeyTrendsWorkspace(api: api, screen: screen),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    final bridge = t
        .widget<TotalReportView>(find.byType(TotalReportView))
        .bridge;
    var replies = 0;
    bridge.send = (_) async {
      replies++;
    };
    bridge.receive({'channel': 'hmi-key-trends-v1', 'type': 'ready'});
    bridge.receive({
      'channel': 'hmi-key-trends-v1',
      'type': 'query',
      'id': 'q',
      'from': '2026-11-16',
      'to': '2026-11-16',
      'stations': ['A'],
    });
    await t.pump();
    await t.pumpWidget(const SizedBox());
    api.pending!.complete({});
    await t.pump();
    expect(replies, 0);
    expect(t.takeException(), isNull);
  });
}
