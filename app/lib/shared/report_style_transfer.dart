import 'dart:convert';
import 'api.dart';
import 'report_time.dart';

// Only presentation settings cross this boundary. Queries and credentials are
// never included or applied from a report style file.
const reportStyleFormat = 'universal-hmi-report-style';

Json validateReportStyle(Object? value, List<String> fields) {
  Never invalid(String detail) => throw FormatException(detail);
  bool name(Object? v, int max, {bool empty = false}) =>
      v is String &&
      (empty || v.trim().isNotEmpty) &&
      utf8.encode(v).length <= max &&
      !RegExp(r'[\x00\r\n]').hasMatch(v);
  bool integer(Object? v, int min, int max, {bool zero = false}) =>
      v is int && ((zero && v == 0) || (v >= min && v <= max));
  if (value is! Map) invalid('缺少报表样式');
  final raw = value['columns'];
  if (raw is! List || raw.isEmpty || raw.length > 128) invalid('列数须为1至128');
  final seen = <String>{};
  final columns = <Json>[];
  for (final c in raw) {
    if (c is! Map || !fields.contains(c['key']) || !seen.add('${c['key']}')) {
      invalid('字段标识未知或重复；请从当前报表重新导出');
    }
    if (c['time_zone'] != null && !validReportTimeZone(c['time_zone'])) {
      invalid('时间列须配置有效的来源和显示时区（UTC-14:00 至 UTC+14:00）');
    }
    if (!name(c['label'], 256) ||
        c['visible'] is! bool ||
        (c['width'] != null && !integer(c['width'], 55, 800, zero: true)) ||
        ![null, '', 'left', 'center', 'right'].contains(c['align']) ||
        (c['decimals'] != null && !integer(c['decimals'], 0, 6)) ||
        (c['group'] != null && !name(c['group'], 128, empty: true))) {
      invalid('列名、显隐、宽度、对齐、小数位或表头组无效');
    }
    columns.add({
      for (final k in [
        'key',
        'label',
        'visible',
        'width',
        'align',
        'decimals',
        'group',
        'time_zone',
      ])
        if (c[k] != null) k: c[k],
    });
  }
  if (seen.length != fields.length) invalid('字段不完整；删除列请改 visible 为 false');
  if (!columns.any((c) => c['visible'] == true)) invalid('当前结果至少保留一列');
  final aliases = value['group_labels'] ?? <String, dynamic>{};
  if (aliases is! Map ||
      aliases.length > 128 ||
      aliases.entries.any((e) => !name(e.key, 2048) || !name(e.value, 256))) {
    invalid('上层标题无效');
  }
  for (final k in ['header_color', 'stripe_color']) {
    if (value[k] != null &&
        (value[k] is! String ||
            !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value[k]))) {
      invalid('颜色须为 #RRGGBB');
    }
  }
  if ((value['row_height'] != null && !integer(value['row_height'], 28, 64)) ||
      (value['font_size'] != null && !integer(value['font_size'], 10, 20))) {
    invalid('行高或字号无效');
  }
  return {
    'columns': columns,
    'group_labels': Map<String, dynamic>.from(aliases),
    for (final k in ['header_color', 'stripe_color', 'row_height', 'font_size'])
      if (value[k] != null) k: value[k],
  };
}

Json decodeReportStyle(
  String text, {
  required String table,
  required String kind,
  required List<String> fields,
}) {
  if (utf8.encode(text).length > 1024 * 1024) {
    throw const FormatException('样式文件不能超过1 MiB');
  }
  final data = jsonDecode(text);
  if (data is! Map ||
      data['format'] != reportStyleFormat ||
      data['version'] != 1) {
    throw const FormatException('不是支持的报表样式文件');
  }
  if (data['table_key'] != table || data['screen_kind'] != kind) {
    throw const FormatException('报表类型不匹配；请从当前表格导出后编辑');
  }
  return validateReportStyle(data['layout'], fields);
}
