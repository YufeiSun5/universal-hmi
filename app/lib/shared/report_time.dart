import 'api.dart';

String reportTimeZoneLabel(int minutes) =>
    'UTC${minutes < 0 ? '-' : '+'}${(minutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(minutes.abs() % 60).toString().padLeft(2, '0')}';

bool validReportTimeZone(Object? value) =>
    value is Map &&
    [
      'source_offset_minutes',
      'target_offset_minutes',
    ].every((key) => value[key] is int && (value[key] as int).abs() <= 840);

final _reportTimestamp = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})?$',
);

/// Fixed-offset conversion independent of the browser/OS timezone. Date-only,
/// invalid and non-time cells keep their original text; source data is untouched.
String reportTime(String value, Json zone) {
  if (!validReportTimeZone(zone)) return value;
  final m = _reportTimestamp.firstMatch(value);
  if (m == null) return value;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
  final t = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (t.year != parts[0] ||
      t.month != parts[1] ||
      t.day != parts[2] ||
      t.hour != parts[3] ||
      t.minute != parts[4] ||
      t.second != parts[5]) {
    return value;
  }
  var source = zone['source_offset_minutes'] as int;
  final suffix = m[8];
  if (suffix == 'Z') {
    source = 0;
  } else if (suffix != null) {
    final digits = suffix.substring(1).replaceAll(':', '');
    final hours = int.parse(digits.substring(0, 2));
    final minutes = int.parse(digits.substring(2));
    if (hours > 14 || minutes > 59 || (hours == 14 && minutes != 0)) {
      return value;
    }
    source = (hours * 60 + minutes) * (suffix.startsWith('-') ? -1 : 1);
  }
  final converted = t.add(
    Duration(minutes: (zone['target_offset_minutes'] as int) - source),
  );
  if (converted.year < 1 || converted.year > 9999) return value;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${converted.year.toString().padLeft(4, '0')}-${two(converted.month)}-${two(converted.day)} '
      '${two(converted.hour)}:${two(converted.minute)}'
      '${m[6] == null ? '' : ':${two(converted.second)}'}${m[7] ?? ''}';
}
