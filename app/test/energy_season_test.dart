import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/shared/api.dart';

class EnergySeasonApi extends Fake implements PlatformApi {
  final queries = <Json>[];

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'code': '02-002', 'name': '北站三号炉站'},
        ],
      };
    }
    if (method == 'POST') {
      final input = body as Json;
      queries.add(input);
      return {
        'statistics': [
          if (input['mode'] == 'season')
            for (final site in {'02-002': '北站三号炉站', '03-004': '壹品桃源三期'}.entries)
              {
                'date': '2026–2027采暖季',
                'station': site.key,
                'name': site.value,
                'label': '水',
                'metric': 'water',
                'day_usage': site.key == '02-002' ? '81' : null,
                'unit': 't',
              },
          if (input['mode'] == 'intensity')
            {
              'date': input['from'],
              'station': '02-002-01',
              'name': '北三南线',
              'label': '水单耗',
              'metric': 'water',
              'day_usage': '4',
              'unit': 't',
              'area_m2': '400',
              'intensity': '0.010000000000',
              'intensity_unit': 't/㎡',
            },
        ],
      };
    }
    return {};
  }
}

void main() {
  testWidgets('season opens with whole sites and no zone selection', (
    tester,
  ) async {
    final api = EnergySeasonApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatisticsQuery(
            api: api,
            screen: const {
              'id': 'daily-season',
              'query_id': 'daily',
              'kind': 'season',
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.queries.single['mode'], 'season');
    expect(api.queries.single['station'], '');
    expect(find.text('站区'), findsNothing);
    expect(find.text('北站三号炉站'), findsOneWidget);
    expect(find.text('壹品桃源三期'), findsOneWidget);
  });

  testWidgets('energy exposes date range and displays zone intensity', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1450, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = EnergySeasonApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatisticsQuery(
            api: api,
            screen: const {'id': 'energy', 'kind': 'energy'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.queries.single['mode'], 'current');
    await tester.tap(find.text('当前总览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单耗统计').last);
    await tester.pumpAndSettle();
    expect(find.text('开始日期（含）'), findsOneWidget);
    expect(find.text('结束日期（含）'), findsOneWidget);
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    final input = api.queries.last;
    expect(input['mode'], 'intensity');
    expect(input['from'], isNotEmpty);
    expect(input['from'], input['to']);
    expect(find.text('北三南线'), findsOneWidget);
    expect(find.text('0.010000'), findsOneWidget);
  });
}
