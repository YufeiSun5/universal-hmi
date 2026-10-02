import '../shared/api.dart';

/// Summaries cover only the explicitly loaded page and preserve frozen units.
List<Json> summarizeHistoryPage(List<Json> rows) {
  final groups = <(String, String, String, String), List<Json>>{};
  for (final row in rows) {
    groups
        .putIfAbsent((
          '${row['point_id']}',
          '${row['station']}',
          '${row['unit']}',
          '${row['version']}',
        ), () => [])
        .add(row);
  }
  return groups.values.map((samples) {
    final first = samples.first;
    final valid = samples
        .where(
          (r) =>
              r['value'] is num &&
              (r['value'] as num).isFinite &&
              ['good', 'imported'].contains(r['quality']),
        )
        .toList();
    num? low, high;
    double mean = 0;
    int seen = 0;
    Json? latest;
    int latestTime = -1;
    for (final sample in valid) {
      final value = sample['value'] as num;
      low = low == null || value < low ? value : low;
      high = high == null || value > high ? value : high;
      seen++;
      final number = value.toDouble();
      mean = mean.isNegative == number.isNegative
          ? mean + (number - mean) / seen
          : mean * ((seen - 1) / seen) + number / seen;
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
      'version': first['version'],
      'count': samples.length,
      'valid': valid.length,
      'min': low,
      'max': high,
      'mean': valid.isEmpty ? null : mean,
      'latest': latest?['value'],
    };
  }).toList();
}

/// Display local wall time while API queries continue to use UTC instants.
String historyInputTime(DateTime value) =>
    value.toLocal().toIso8601String().replaceFirst('T', ' ').substring(0, 19);

/// DateTime.tryParse alone silently normalizes impossible calendar dates.
/// Accept local wall time or explicit ISO offsets, but reject overflow components.
DateTime? parseHistoryTime(String text) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(?:[Zz]|([+-])(\d{2}):?(\d{2}))?)?$',
  ).firstMatch(text);
  if (match == null) return null;
  int component(int i) => int.tryParse(match.group(i) ?? '0') ?? -1;
  final year = component(1), month = component(2), day = component(3);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      component(4) > 23 ||
      component(5) > 59 ||
      component(6) > 59 ||
      component(8) > 23 ||
      component(9) > 59) {
    return null;
  }
  return DateTime.tryParse(text);
}
