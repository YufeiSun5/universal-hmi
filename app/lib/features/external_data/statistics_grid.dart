import 'dart:convert';
import '../../shared/api.dart';
import 'daily_reading.dart';

/// A display pivot only: every cell comes from one database statistic. The
/// caller chooses display fields; this grid never aggregates or invents values.
class StatisticsGrid {
  StatisticsGrid({
    required List<Json> records,
    required List<Json> columns,
    required bool energy,
    required String mode,
    required this.format,
    bool includeEmptyMetrics = true,
  }) {
    const identity = {'date', 'station', 'hour', 'progress'};
    final shared = columns.where((c) => identity.contains(c['key'])).toList();
    final values = columns
        .where(
          (c) =>
              !identity.contains(c['key']) &&
              c['key'] != 'label' &&
              c['key'] != 'unit',
        )
        .toList();
    final metrics = <String, Json>{};
    final metricRecords = <String, List<Json>>{};
    final groups = <String, Map<String, Json>>{};
    for (final r in records) {
      final metric = jsonEncode([r['metric'], r['label'], r['unit']]);
      metrics.putIfAbsent(metric, () => r);
      metricRecords.putIfAbsent(metric, () => []).add(r);
      final row = jsonEncode([
        r['date'],
        r['station'],
        if (mode == 'hourly') r['hour'],
      ]);
      groups.putIfAbsent(row, () => {})[metric] = r;
    }
    final order = metrics.keys.toList();
    if (energy) {
      const rank = {'water': 0, 'electricity': 1, 'heat': 2};
      order.sort(
        (a, b) => (rank[metrics[a]!['metric']] ?? 3).compareTo(
          rank[metrics[b]!['metric']] ?? 3,
        ),
      );
    }
    for (final c in shared) {
      headers.add(c['label'] as String);
      headerGroups.add('');
      headerGroupKeys.add('');
      fields.add((null, c['key'] as String));
    }
    final showLabel = columns.any((c) => c['key'] == 'label');
    final showUnit = columns.any((c) => c['key'] == 'unit');
    for (final metric in order) {
      final r = metrics[metric]!;
      final caption = [
        if (showLabel) '${r['label']}',
        if (showUnit && '${r['unit'] ?? ''}'.isNotEmpty) '(${r['unit']})',
      ].join(' ');
      final samples = metricRecords[metric]!;
      final prefix = mode == 'daily' ? 'day' : 'hour';
      final hasUsage = samples.any((r) => r['${prefix}_usage'] != null);
      final hasRange = samples.any(
        (r) => r['${prefix}_min'] != null || r['${prefix}_max'] != null,
      );
      if (!includeEmptyMetrics &&
          !energy &&
          mode == 'hourly' &&
          !hasUsage &&
          !hasRange) {
        continue;
      }
      for (final c in values) {
        final key = c['key'] as String;
        // Hide only structurally empty alternatives when the same metric has
        // actual values of the other kind. Entirely missing metrics stay visible.
        if (!energy &&
            hasUsage &&
            !hasRange &&
            (key == '${prefix}_min' || key == '${prefix}_max')) {
          continue;
        }
        if (!energy && hasRange && !hasUsage && key == '${prefix}_usage') {
          continue;
        }
        final kinds = samples.map(dailyReadingKind).toSet();
        headers.add(
          key == 'day_value' && c['label'] == '用量/范围'
              ? kinds.length == 1 && kinds.single == 'range'
                    ? '范围'
                    : kinds.length == 1 && kinds.single == 'usage'
                    ? '用量'
                    : '用量/范围'
              : c['label'] as String,
        );
        headerGroups.add(caption);
        headerGroupKeys.add(metric);
        fields.add((metric, key));
      }
    }
    rows.addAll(groups.values);
  }

  final String Function(Json, String, {bool exporting}) format;
  final headers = <String>[];
  final headerGroups = <String>[];
  final headerGroupKeys = <String>[];
  final fields = <(String?, String)>[];
  final rows = <Map<String, Json>>[];
  List<String> get columnKeys => [
    for (final field in fields)
      field.$1 == null ? field.$2 : '${field.$1} / ${field.$2}',
  ];

  List<double> get widths => [
    for (final f in fields)
      if (f.$2 == 'station')
        190
      else if (f.$2 == 'hour' || f.$2.startsWith('sample_'))
        190
      else if (f.$2.endsWith('_status'))
        150
      else
        120,
  ];
  Set<int> get numericColumns => {
    for (var i = 0; i < fields.length; i++)
      if ((fields[i].$2 == 'day_value' ||
              RegExp(r'_(usage|min|max|subtotal)$').hasMatch(fields[i].$2)) &&
          !fields[i].$2.startsWith('sample_'))
        i,
  };
  List<String> get exportHeaders => [
    for (var i = 0; i < headers.length; i++)
      headerGroups[i].isEmpty
          ? headers[i]
          : '${headerGroups[i]} · ${headers[i]}',
  ];
  List<String> cells(
    int index, {
    bool exporting = false,
    bool rawTime = false,
  }) {
    final row = rows[index];
    String value((String?, String) field) {
      final source = field.$1 == null ? row.values.first : row[field.$1] ?? {};
      if (rawTime &&
          const {'hour', 'sample_min', 'sample_max'}.contains(field.$2)) {
        return source[field.$2]?.toString() ?? '—';
      }
      return format(source, field.$2, exporting: exporting);
    }

    return [for (final f in fields) value(f)];
  }
}
