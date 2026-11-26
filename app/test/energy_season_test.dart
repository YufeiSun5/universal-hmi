import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
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
    if (path == '/api/v1/external/screens') {
      return {
        'items': [
          {'id': 'energy', 'name': '能耗管理', 'kind': 'energy'},
        ],
      };
    }
    if (path.endsWith('/stations')) {
      if (query?['scope'] == 'heat_meters') {
        return {
          'items': [
            {'code': '02-002', 'name': '北站'},
          ],
        };
      }
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
              'date': input['date'],
              'station': '02-002-01',
              'name': input['metric'] == 'water' ? '北三南线' : '北站',
              'label': energyIntensityNames[input['metric']],
              'metric': input['metric'],
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

  testWidgets('separate sidebar intensity pages share the period selector', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1450, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = EnergySeasonApi();
    final catalog = ExternalCatalog(api, canDevelop: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EnergyWorkspace(catalog: catalog)),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.queries.single['mode'], 'current');
    for (final entry in energyIntensityNames.entries) {
      await tester.tap(find.text(entry.value).first);
      await tester.pumpAndSettle();
      expect(api.queries.last['metric'], entry.key);
      expect(api.queries.last['period'], 'daily');
      if (entry.key == 'heat') expect(find.text('全部热表'), findsOneWidget);
    }
    await tester.tap(find.text('水单耗').first);
    await tester.pumpAndSettle();
    final periods = {
      '日': ('daily', '日期'),
      '月': ('monthly', '月份（选择任一天）'),
      '采暖季': ('season', '采暖季（选择季内日期）'),
      '自选日期': ('range', '开始日期（含）'),
    };
    var selected = '日';
    for (final entry in periods.entries) {
      if (selected != entry.key) {
        await tester.tap(find.text(selected));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.key).last);
        await tester.pumpAndSettle();
        selected = entry.key;
      }
      expect(find.text(entry.value.$2), findsOneWidget);
      final range = entry.value.$1 == 'range';
      expect(find.text('结束日期（含）'), range ? findsOneWidget : findsNothing);
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      final input = api.queries.last;
      expect(input['mode'], 'intensity');
      expect(input['metric'], 'water');
      expect(input['period'], entry.value.$1);
      expect(input['date'], isNotEmpty);
      expect(input['from'], range ? input['date'] : '');
      expect(input['to'], range ? input['date'] : '');
    }
    expect(find.text('北三南线'), findsOneWidget);
    expect(find.text('0.010000'), findsOneWidget);
  });
}
