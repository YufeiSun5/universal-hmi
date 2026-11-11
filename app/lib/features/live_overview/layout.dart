import '../../shared/api.dart';

/// Only selected columns have a second equipment reading. Missing second
/// bindings never fall back to the first equipment's point.
Set<String> overviewSplitColumns(Json row) => {
  for (final id in ((row['additional'] as Map?)?['columns'] as List? ?? []))
    if (id is String) id,
};

String overviewParentID(Json row) =>
    (row['_overview_parent'] ?? row['id']) as String;

bool overviewIsSplit(Json row, Object? column) =>
    (row['_overview_split'] as Set<String>?)?.contains(column) ?? false;

int overviewDisplayCellCount(List<Json> rows, List<Json> columns) =>
    columns.length *
    (rows.length +
        rows.where((r) => overviewSplitColumns(r).isNotEmpty).length);

/// Expand for rendering/export only. Saved row IDs, station ownership, control
/// identity and the original bindings are not changed.
List<Json> overviewDisplayRows(List<Json> rows, List<Json> columns) {
  final visible = columns.map((c) => c['id']).toSet();
  return [
    for (var i = 0; i < rows.length; i++) ..._expandRow(rows[i], i, visible),
  ];
}

List<Json> _expandRow(Json row, int index, Set<Object?> visible) {
  final split = overviewSplitColumns(row).intersection(visible.cast<String>());
  if (split.isEmpty) {
    return [
      {...row, '_overview_index': index},
    ];
  }
  final original = (row['bindings'] as Map?) ?? {};
  final second = (row['additional'] as Map?)?['bindings'] as Map? ?? {};
  return [
    for (var part = 1; part <= 2; part++)
      {
        ...row,
        'id': part == 1 ? row['id'] : '${row['id']}::2',
        '_overview_parent': row['id'],
        '_overview_index': index,
        '_overview_part': part,
        '_overview_split': split,
        'bindings': part == 1
            ? original
            : {
                for (final e in original.entries)
                  if (!split.contains(e.key)) e.key as String: e.value,
                for (final id in split)
                  if (second[id] case final String point) id: point,
              },
      },
  ];
}

Iterable<String> overviewPointIDs(List<Json> rows, List<Json> columns) sync* {
  for (final row in overviewDisplayRows(rows, columns)) {
    for (final column in columns) {
      final id = (row['bindings'] as Map?)?[column['id']];
      if (id is String && id.isNotEmpty) yield id;
    }
  }
}

String overviewEquipmentNumber(Json row) =>
    row['_overview_part'] == 2 ? '②' : '①';

/// One marker at the start of each split group keeps narrow tables readable.
bool overviewShowEquipmentNumber(Json row, Json column, List<Json> columns) {
  if (!overviewIsSplit(row, column['id'])) return false;
  for (final c in columns) {
    if (c['group'] == column['group'] && overviewIsSplit(row, c['id'])) {
      return c['id'] == column['id'];
    }
  }
  return false;
}
