import 'dart:convert';
import 'dart:typed_data';

import '../../shared/api.dart';
import 'layout.dart';

/// Only presentation configuration travels in this file. Point definitions and
/// the destination revision always belong to the currently open project.
Uint8List encodeOverview(
  List<Json> columns,
  List<Json> rows,
  Object? outdoor, {
  Object? control,
}) => Uint8List.fromList(
  utf8.encode(
    const JsonEncoder.withIndent('  ').convert({
      'format': 'universal-hmi-live-overview',
      'version': 1,
      'columns': columns,
      'rows': rows,
      'outdoor': outdoor ?? {},
      'control': ?control,
    }),
  ),
);

class OverviewImport {
  OverviewImport(
    this.columns,
    this.rows,
    this.outdoor,
    this.missing, {
    this.control,
  });
  final List<Json> columns, rows;
  final Json outdoor;
  final List<String> missing;
  final Json? control;

  /// Update only imported stable column/row identities. Custom columns and
  /// their bindings survive on standard rows, as do all unrelated rows.
  ({List<Json> columns, List<Json> rows}) merge(
    List<Json> oldColumns,
    List<Json> oldRows,
    List<Json> selected,
  ) {
    final byColumn = {for (final c in columns) c['id']: c};
    final byRow = {for (final r in selected) r['id']: r};
    final oldColumnIDs = oldColumns.map((c) => c['id']).toSet();
    final oldRowIDs = oldRows.map((r) => r['id']).toSet();
    final mergedColumns = [
      for (final c in oldColumns)
        if (byColumn[c['id']] case final incoming?)
          {
            ...incoming,
            if (incoming['desktop_visible'] == null &&
                c['desktop_visible'] is bool)
              'desktop_visible': c['desktop_visible'],
          }
        else
          c,
    ];
    // New standard columns belong next to their imported neighbors, rather
    // than at the end of the entire table. Existing custom columns retain
    // their relative order and content.
    for (var i = 0; i < columns.length; i++) {
      final column = columns[i];
      if (oldColumnIDs.contains(column['id'])) continue;
      var insertAt = -1;
      for (var j = i - 1; j >= 0 && insertAt < 0; j--) {
        final previous = mergedColumns.indexWhere(
          (c) => c['id'] == columns[j]['id'],
        );
        if (previous >= 0) insertAt = previous + 1;
      }
      for (var j = i + 1; j < columns.length && insertAt < 0; j++) {
        insertAt = mergedColumns.indexWhere((c) => c['id'] == columns[j]['id']);
      }
      mergedColumns.insert(
        insertAt < 0 ? mergedColumns.length : insertAt,
        column,
      );
    }
    Json combine(Json old, Json incoming) {
      final result = <String, dynamic>{
        ...old,
        ...incoming,
        'bindings': {
          for (final e in (old['bindings'] as Map).entries)
            if (!byColumn.containsKey(e.key)) e.key: e.value,
          ...incoming['bindings'] as Map,
        },
      };
      // Old files do not mention additional equipment: leave it intact.
      // New files replace only their own columns, retaining custom splits.
      if (incoming.containsKey('additional')) {
        final custom = overviewSplitColumns(
          old,
        ).where((id) => !byColumn.containsKey(id)).toSet();
        final selected = {...custom, ...overviewSplitColumns(incoming)};
        result['additional'] = {
          'columns': selected.toList(),
          'bindings': {
            for (final e
                in ((old['additional'] as Map?)?['bindings'] as Map? ?? {})
                    .entries)
              if (custom.contains(e.key)) e.key: e.value,
            ...((incoming['additional'] as Map?)?['bindings'] as Map? ?? {}),
          },
        };
      }
      return result;
    }

    return (
      columns: mergedColumns,
      rows: [
        for (final r in oldRows)
          if (byRow[r['id']] case final Json next) combine(r, next) else r,
        for (final r in selected)
          if (!oldRowIDs.contains(r['id'])) r,
      ],
    );
  }

  static OverviewImport decode(Uint8List bytes, Map<String, Json> definitions) {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('总览文件超过 8 MiB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Json ||
        raw['format'] != 'universal-hmi-live-overview' ||
        raw['version'] != 1 ||
        raw['columns'] is! List ||
        raw['rows'] is! List ||
        raw['outdoor'] is! Json) {
      throw const FormatException('请选择版本 1 的总览配置 JSON');
    }
    final columns = (raw['columns'] as List).whereType<Json>().toList();
    final rows = (raw['rows'] as List).whereType<Json>().toList();
    if (columns.length != raw['columns'].length ||
        rows.length != raw['rows'].length ||
        columns.length > 64 ||
        rows.length > 256 ||
        columns.length * rows.length > 8192) {
      throw const FormatException('总览行列格式或数量无效');
    }
    final pattern = RegExp(r'^[a-zA-Z0-9_-]{1,96}$');
    bool validID(dynamic id) => id is String && pattern.hasMatch(id);
    bool label(dynamic v) => v is String && v.trim().isNotEmpty;
    final colIDs = <String>{}, rowIDs = <String>{};
    for (final c in columns) {
      if (!validID(c['id']) ||
          !colIDs.add(c['id']) ||
          !label(c['group']) ||
          !label(c['name']) ||
          c['decimals'] is! int ||
          c['decimals'] < 0 ||
          c['decimals'] > 6 ||
          (c['header'] ?? '') is! String ||
          (c['unit'] ?? '') is! String) {
        throw const FormatException('指标列格式无效或标识重复');
      }
      if (c['desktop_visible'] != null && c['desktop_visible'] is! bool) {
        throw const FormatException('桌面列显示设置必须为布尔值');
      }
    }
    // Generated site templates use an exact source ID + acquisition path.
    // Ambiguous paths remain empty and are reported before replacing the draft.
    final paths = <(String, String), List<String>>{};
    for (final e in definitions.entries) {
      final source = e.value['source_id'], path = e.value['source_path'];
      if (source is String && path is String) {
        paths.putIfAbsent((source, path), () => []).add(e.key);
      }
    }
    final missing = <String>[];
    final control = raw['control'];
    if (control != null &&
        (control is! Json ||
            control['enabled'] is! bool ||
            (control['base_url'] ?? '') is! String)) {
      throw const FormatException('接管状态服务配置无效');
    }
    String? resolve(dynamic ref, String location) {
      if (ref is String && validID(ref)) {
        if (definitions.containsKey(ref)) return ref;
        throw FormatException('$location 引用当前工程不存在的变量 $ref');
      }
      if (ref is! Json ||
          !label(ref['source_id']) ||
          !label(ref['source_path'])) {
        throw FormatException('$location 的变量引用无效');
      }
      final matches = paths[(ref['source_id'], ref['source_path'])];
      if (matches?.length == 1) return matches!.single;
      missing.add('$location · ${ref['source_path']}');
      return null;
    }

    for (final row in rows) {
      final binding = row['control'];
      if (binding != null &&
          (binding is! Json ||
              (binding['station'] ?? '') is! String ||
              (binding['zone'] ?? '') is! String)) {
        throw const FormatException('接管状态站区对应关系无效');
      }
      if (!validID(row['id']) ||
          !rowIDs.add(row['id']) ||
          !label(row['name']) ||
          !label(row['station']) ||
          (row['site'] ?? '') is! String ||
          (row['area'] ?? '') is! String ||
          row['bindings'] is! Json) {
        throw const FormatException('站点行格式无效或标识重复');
      }
      final bindings = <String, String>{};
      for (final e in (row['bindings'] as Json).entries) {
        if (!colIDs.contains(e.key)) throw const FormatException('绑定的指标列不存在');
        final id = resolve(e.value, '${row['station']} / ${e.key}');
        if (id != null) bindings[e.key] = id;
      }
      row['bindings'] = bindings;
      final extra = row['additional'];
      if (extra != null) {
        if (extra is! Json ||
            extra['columns'] is! List ||
            extra['bindings'] is! Json) {
          throw const FormatException('附加行格式无效');
        }
        final selected = <String>{};
        for (final col in extra['columns'] as List) {
          if (col is! String || !colIDs.contains(col) || !selected.add(col)) {
            throw const FormatException('附加行的指标列不存在或重复');
          }
        }
        final second = <String, String>{};
        for (final e in (extra['bindings'] as Json).entries) {
          if (!selected.contains(e.key)) {
            throw const FormatException('第二组绑定须属于分行指标');
          }
          final id = resolve(e.value, '${row['station']} / ${e.key} / 第二组');
          if (id != null) second[e.key] = id;
        }
        row['additional'] = {'columns': selected.toList(), 'bindings': second};
      }
    }
    if (overviewDisplayCellCount(rows, columns) > 8192) {
      throw const FormatException('总览最多8192个显示单元格（含附加行）');
    }
    final outdoor = raw['outdoor'] as Json;
    final ref = outdoor['point_id'];
    final id = ref == null || ref == '' ? null : resolve(ref, '室外温度');
    return OverviewImport(
      columns,
      rows,
      {'point_id': ?id},
      missing,
      control: control as Json?,
    );
  }
}
