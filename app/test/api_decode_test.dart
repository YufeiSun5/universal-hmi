import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  test('Large native JSON retains 15000 values and Chinese names', () async {
    final data = {
      'values': List.generate(
        15000,
        (i) => {
          'id': 'p$i',
          'station': '站点${i ~/ 500}',
          'value': i,
          'quality': 'good',
        },
      ),
    };
    final decoded = await decodeResponseObject(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
    );
    expect(decoded, data);
  });
  test('Snapshot maps are not cloned while edit maps are copied', () {
    final row = <String, dynamic>{'value': 7};
    expect(identical(snapshotObjects([row]).single, row), true);
    objects([row]).single['value'] = 8;
    expect(row['value'], 7);
  });
  test('Malformed large JSON is rejected', () async {
    await expectLater(
      decodeResponseObject(Uint8List.fromList(List.filled(300000, 123))),
      throwsA(isA<FormatException>()),
    );
  });
}
