import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/cockpit/config_transfer.dart';
import 'package:universal_hmi/features/cockpit/settings.dart';
import 'package:universal_hmi/shared/api.dart';

class CockpitSettingsApi extends Fake implements PlatformApi {
  Json? saved;

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (method == 'PUT') {
      saved = body as Json;
      return {...saved!, 'revision': 2};
    }
    if (path == '/api/v1/live-overview') return {'rows': []};
    if (path == '/api/v1/external/screens') {
      return {
        'items': [
          {'id': 'energy', 'name': '能耗管理', 'kind': 'energy'},
        ],
      };
    }
    if (path == '/api/v1/external/screens/energy/stations') {
      expect(query, {'scope': 'water_zones'});
      return {
        'items': [
          {'code': '02-002-01', 'name': '北站南线区'},
        ],
      };
    }
    return {
      'revision': 1,
      'title': '供热驾驶舱',
      'delay_minutes': 3,
      'offline_minutes': 5,
      'rank_area_m2': {'02-002': 100},
      'heat_sites': [
        {'code': '02-002', 'name': '北站', 'confirm_area': true},
      ],
      'energy_sites': [
        {'code': '02-002', 'name': '北站三号炉站'},
        {'code': '03-004', 'name': '壹品桃源三期'},
      ],
    };
  }
}

void main() {
  testWidgets('edit, save, and transfer meter and water zone areas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1250, 1450));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = CockpitSettingsApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CockpitSettings(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('单耗排行配置'));
    await tester.pumpAndSettle();
    final fields = {
      '热': ('heat', '02-002', '420', ''),
      '电': ('electricity', '02-002', '230', '100'),
      '水': ('water', '02-002', '210', '100'),
      '分区水': ('water_zone', '02-002-01', '90', ''),
    };
    for (final entry in fields.entries) {
      final heading = find.text('${entry.key}面积（㎡）').first;
      await tester.ensureVisible(heading);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      final input = find.byKey(
        ValueKey('rank-area-${entry.value.$1}-${entry.value.$2}'),
      );
      final field = tester.widget<TextFormField>(input);
      expect(field.controller!.text, entry.value.$4);
      await tester.ensureVisible(input);
      await tester.enterText(input, entry.value.$3);
    }
    expect(find.byKey(const ValueKey('rank-area-heat-03-004')), findsNothing);
    expect(
      find.byKey(const ValueKey('rank-area-water-03-004')),
      findsOneWidget,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = api.saved!;
    final expected = {
      'heat': {'02-002': 420.0},
      'electricity': {'02-002': 230.0},
      'water': {'02-002': 210.0},
      'water_zone': {'02-002-01': 90.0},
    };
    expect(saved['rank_areas_m2'], expected);
    expect(
      decodeCockpitConfig(encodeCockpitConfig(saved))['rank_areas_m2'],
      expected,
    );
    expect(
      () => decodeCockpitConfig(
        encodeCockpitConfig({
          ...saved,
          'rank_areas_m2': {
            'heat': {'02-002': 0},
          },
        }),
      ),
      throwsFormatException,
    );
  });
}
