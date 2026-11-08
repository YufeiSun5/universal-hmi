import 'dart:convert';
import 'dart:typed_data';
import '../platform/save.dart';
import 'api.dart';
import 'report_style.dart';

class TableCsv {
  TableCsv({
    this.styles,
    this.sourceHeaders,
    this.headerGroups,
    this.headerGroupKeys,
  });
  final ReportStyles? styles;
  final List<String>? sourceHeaders, headerGroups, headerGroupKeys;
  bool _first = true;
  ReportProjection? _projection;
  final _output = StringBuffer('\uFEFF');

  void add(List<String> fields) {
    if (_first && sourceHeaders != null && styles != null) {
      final keys = reportColumnKeys(
        sourceHeaders!,
        groups: headerGroups,
        groupKeys: headerGroupKeys,
      );
      final layout = styles!.layout(keys, displayLabels: sourceHeaders);
      if (layout.isEmpty) {
        _first = false;
        _write(fields);
        return;
      }
      _projection = ReportProjection(
        keys,
        layout,
        labels: {
          for (var i = 0; i < keys.length; i++) keys[i]: sourceHeaders![i],
        },
      );
      fields = [
        for (final col in _projection!.columns)
          [
            if ('${col['group'] ?? headerGroups?[keys.indexOf('${col['key']}')] ?? ''}'
                .isNotEmpty)
              '${col['group'] ?? headerGroups?[keys.indexOf('${col['key']}')]}',
            '${col['label'] ?? col['key']}',
          ].join(' · '),
      ];
      _first = false;
      _write(fields);
      return;
    }
    _first = false;
    final key = reportSchemaKey(
      fields,
      custom: styles?.screen['kind'] == 'custom',
    );
    final schema = styles?.schemas[key];
    final isHeader =
        schema != null &&
        schema.length == fields.length &&
        List.generate(
          fields.length,
          (i) => schema[i] == fields[i],
        ).every((v) => v);
    if (isHeader) {
      _projection = ReportProjection(fields, styles!.layout(fields));
      fields = _projection!.headers;
    } else if (_projection != null) {
      fields = _projection!.row(fields, raw: true);
    }
    _write(fields);
  }

  void _write(List<String> fields) {
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
