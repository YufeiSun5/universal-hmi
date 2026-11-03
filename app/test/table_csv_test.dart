import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/table_csv.dart';

void main() {
  test('CSV preserves display text, escapes quotes and guards formulas', () {
    final csv = TableCsv()
      ..add(['分区', '值'])
      ..add(['二,区"北"', '=1+1'])
      ..add(['换\n行', '-0.2']);
    expect(
      utf8.decode(csv.bytes, allowMalformed: false),
      '"分区","值"\r\n"二,区""北""","\'=1+1"\r\n"换\n行","-0.2"\r\n',
    );
    expect(csv.bytes.take(3), [239, 187, 191]);
  });
  test(
    'full query export includes row 501 and aborts on config change',
    () async {
      final result = <int>[];
      Future<void> collect(bool changed) => collectReportPages(
        displayed: {'screen_revision': 3},
        rowsKey: 'events',
        active: () => true,
        fetch: (offset) async => {
          'screen_revision': offset > 0 && changed ? 4 : 3,
          'offset': offset,
          'has_more': offset == 0,
          'events': [
            for (var i = offset; i < (offset == 0 ? 500 : 501); i++) {'i': i},
          ],
        },
        add: (r) => result.add(r['i'] as int),
      );
      await collect(false);
      expect(result, List.generate(501, (i) => i));
      await expectLater(collect(true), throwsStateError);
    },
  );
}
