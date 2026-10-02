import '../shared/api.dart';

/// Summaries cover only the explicitly loaded page and preserve frozen units.
List<Json> summarizeHistoryPage(List<Json> rows) {
  final groups = <String, List<Json>>{};
  for (final row in rows) {
    groups.putIfAbsent('${row['point_id']}|${row['unit']}', () => []).add(row);
  }
  return groups.values.map((samples) {
    final first = samples.first;
    final valid = samples
        .where(
          (r) =>
              r['value'] is num && ['good', 'imported'].contains(r['quality']),
        )
        .toList();
    num? low, high;
    double sum = 0;
    Json? latest;
    int latestTime = -1;
    for (final sample in valid) {
      final value = sample['value'] as num;
      low = low == null || value < low ? value : low;
      high = high == null || value > high ? value : high;
      sum += value;
      final at =
          DateTime.tryParse(
            sample['source_time'].toString(),
          )?.millisecondsSinceEpoch ??
          -1;
      if (at >= latestTime) {
        latestTime = at;
        latest = sample;
      }
    }
    return <String, dynamic>{
      'point_id': first['point_id'],
      'name': first['name'],
      'station': first['station'],
      'unit': first['unit'],
      'count': samples.length,
      'valid': valid.length,
      'min': low,
      'max': high,
      'mean': valid.isEmpty ? null : sum / valid.length,
      'latest': latest?['value'],
    };
  }).toList();
}
