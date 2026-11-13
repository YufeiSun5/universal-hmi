// Stage in app/test to exercise the actual station-list decoder and merge.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/gis_station_transfer.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  test(
    '1104 current GIS export accepts one-station update with exactly two binding changes',
    () {
      const folder = 'D:/Users/SunYufei/Downloads';
      final current = GisStationListFile.decode(
        File('$folder/gis-stations.json').readAsBytesSync(),
      );
      final update = GisStationListFile.decode(
        File('$folder/03-GIS红光美苑首站-导入站点专用.json').readAsBytesSync(),
      );
      expect(current, hasLength(16));
      expect(update, hasLength(1));
      final merged = GisStationListFile.merge(current, update);
      expect(merged, hasLength(16));
      const id = 'zh-gis-0ce1f3bc25a4cc51';
      final before = current.singleWhere((s) => s['id'] == id);
      final after = merged.singleWhere((s) => s['id'] == id);
      final expected = jsonDecode(jsonEncode(before)) as Json;
      expected['bindings']['zh-m5'] = 'pt_8daa523a649821c8bad49c03';
      expected['bindings']['zh-m6'] = 'pt_474b6cd854b3f34cf2b2d7d8';
      expect(after, expected);
      for (var i = 0; i < current.length; i++) {
        expect(merged[i]['id'], current[i]['id']);
        if (current[i]['id'] != id) expect(merged[i], current[i]);
      }
      final points =
          (jsonDecode(
                    File(
                      'D:/DEV_D/KPimport/.local/update-1104/verified-points.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Json>();
      final known = {for (final point in points) point['id']: point};
      final file = GisStationFile.fromStation(after);
      expect(
        {
          ...file.pointIDs('common'),
          ...file.pointIDs('zones'),
        }.every(known.containsKey),
        isTrue,
      );
      expect(known[after['bindings']['zh-m5']]!['source_path'], '中节能_西站_供水_温度');
      expect(known[after['bindings']['zh-m6']]!['source_path'], '中节能_西站_回水_温度');
      expect(GisStationListFile.merge(merged, update), merged);
    },
  );
}
