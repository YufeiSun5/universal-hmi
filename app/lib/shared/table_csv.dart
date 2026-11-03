import 'dart:convert';
import 'dart:typed_data';
import '../platform/save.dart';
import 'api.dart';

class TableCsv {
  final _output = StringBuffer('\uFEFF');

  void add(List<String> fields) {
    String quote(String s) {
      final value = RegExp(r'^\s*[=+@-]').hasMatch(s) && num.tryParse(s) == null
          ? "'$s"
          : s;
      return '"${value.replaceAll('"', '""')}"';
    }

    _output.write('${fields.map(quote).join(',')}\r\n');
  }

  Uint8List get bytes => Uint8List.fromList(utf8.encode(_output.toString()));
  Future<bool> save(String name) =>
      saveFile(bytes, name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
}

// External detail, trend and alarm queries have a fixed 500-row server page.
Future<void> collectReportPages({
  required Json displayed,
  required Future<Json> Function(int) fetch,
  required String rowsKey,
  required bool Function() active,
  required void Function(Json) add,
}) async {
  String signature(Json p) => jsonEncode([
    p['points'],
    p['mapping_id'],
    p['source_revision'],
    p['screen_revision'],
  ]);
  final expected = signature(displayed);
  for (var offset = 0; active(); offset += 500) {
    final page = await fetch(offset);
    if (!active()) return;
    final rows = objects(page[rowsKey]);
    if (signature(page) != expected ||
        page['offset'] != offset ||
        (page['has_more'] == true && rows.length != 500)) {
      throw StateError('配置或数据页已变化，请重新查询后导出');
    }
    for (final row in rows) {
      add(row);
    }
    if (page['has_more'] != true) return;
  }
}
