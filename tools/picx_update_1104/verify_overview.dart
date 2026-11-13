// Stage in app/test. Verifies delivery through production importers.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/process/gis_station_transfer.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  test(
    '1104 overview and GIS resolve exact existing points and preserve scope',
    () {
      final root = Platform.environment['UPDATE_1104_ROOT']!;
      final out = '$root/outputs/庄河1104更新包';
      final points =
          (jsonDecode(
                    File(
                      '$root/.local/update-1104/verified-points.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Json>();
      final definitions = {
        for (final point in points) point['id'] as String: point,
      };
      final decoded = OverviewImport.decode(
        File('$out/02-数据总览配置.json').readAsBytesSync(),
        definitions,
      );
      expect(decoded.missing, isEmpty);
      expect(decoded.rows, hasLength(31));
      expect(decoded.columns, hasLength(31));
      final raw =
          jsonDecode(File('$out/02-数据总览配置.json').readAsStringSync()) as Json;
      var count = 0;
      for (var i = 0; i < decoded.rows.length; i++) {
        final bindings = decoded.rows[i]['bindings'] as Map;
        final expected = raw['rows'][i]['bindings'] as Map;
        expect(bindings.keys.toSet(), expected.keys.toSet());
        for (final entry in bindings.entries) {
          expect(
            definitions[entry.value]!['source_id'],
            expected[entry.key]['source_id'],
          );
          expect(
            definitions[entry.value]!['source_path'],
            expected[entry.key]['source_path'],
          );
          count++;
        }
      }
      expect(count, 861);
      expect(definitions[decoded.outdoor['point_id']]!['source_path'], '室外温度');
      final center = decoded.rows.singleWhere((r) => r['station'] == '中心站东南区');
      expect(
        definitions[center['bindings']['zh-m25']]!['source_path'],
        '中心站一区主循环泵电流',
      );
      expect(
        definitions[center['bindings']['zh-m27']]!['source_path'],
        '中心站一区辅助循1电流',
      );
      final simple = decoded.rows.singleWhere((r) => r['station'] == '景泰高区');
      expect(
        definitions[simple['bindings']['zh-m25']]!['source_path'],
        '景泰一区循环泵电流',
      );
      expect(simple['bindings'].containsKey('zh-m27'), isFalse);
      final hg = decoded.rows.singleWhere((r) => r['station'] == '红光美苑首站');
      expect(
        definitions[hg['bindings']['zh-m5']]!['source_path'],
        '中节能_西站_供水_温度',
      );
      final zt = decoded.rows.singleWhere((r) => r['station'] == '张屯换热站');
      expect(
        definitions[zt['bindings']['zh-m18']]!['source_path'],
        '张屯站FI201低温水供水累计热量',
      );
      final file = GisStationFile.decode(
        File('$out/03-GIS红光美苑首站-仅公共温度.json').readAsBytesSync(),
      );
      expect(file.parts.keys.toSet(), {'common'});
      final original = <String, dynamic>{
        'id': 'fixture-stable-site',
        'name': '现场名称',
        'longitude': 122.5,
        'latitude': 39.5,
        'target_screen_id': 'existing-screen',
        'fields': <Json>[],
        'bindings': <String, String>{},
        'zones': [
          {
            'id': 'existing-zone',
            'name': '首站',
            'fields': <Json>[],
            'bindings': <String, String>{},
          },
        ],
      };
      final applied = file.apply(original, {'common'});
      for (final key in [
        'id',
        'name',
        'longitude',
        'latitude',
        'target_screen_id',
        'zones',
      ]) {
        expect(applied[key], original[key]);
      }
      expect(
        definitions[applied['bindings']['zh-m5']]!['source_path'],
        '中节能_西站_供水_温度',
      );
      expect(
        definitions[applied['bindings']['zh-m6']]!['source_path'],
        '中节能_西站_回水_温度',
      );
      expect(file.pointIDs('common').every(definitions.containsKey), isTrue);
      final repeat = file.apply(applied, {'common'});
      expect(repeat, applied);
      File(
        '$root/.local/update-1104/overview-gis-verification.json',
      ).writeAsStringSync(
        jsonEncode({
          'overview_import': 'passed',
          'overview_refs': count + 1,
          'pump_left_order': 'preserved',
          'outdoor_reference': 'preserved',
          'gis_common_only_import': 'passed',
          'gis_bound_values': 2,
          'gis_coordinates_zones_target_preserved': true,
          'real_live_data': false,
        }),
      );
    },
  );
}
