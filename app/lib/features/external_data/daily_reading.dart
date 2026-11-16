import '../../shared/api.dart';

String dailyReadingKind(Json row) {
  final kind = row['statistic_kind'];
  if (kind == 'range' || kind == 'usage' || kind == 'mixed') return '$kind';
  // Older servers may not send the type. Infer only from actual non-null data.
  final range = row['day_min'] != null || row['day_max'] != null;
  final usage = row['day_usage'] != null || row['day_subtotal'] != null;
  if (range && usage) return 'mixed';
  return range
      ? 'range'
      : usage
      ? 'usage'
      : 'unknown';
}

/// Select stored results only. Today's latest settled usage is useful before
/// midnight; it is never re-summed or copied into the API's complete-day field.
String dailyReading(
  Json row,
  String Function(Object?) number, {
  bool diagnostics = true,
}) {
  String reading(String text) =>
      row['aggregation'] != null &&
          row['aggregation_incomplete'] == true &&
          text != '—'
      ? '$text（已结算部分）'
      : text;
  switch (dailyReadingKind(row)) {
    case 'range':
      if (row['day_min'] == null && row['day_max'] == null) return '—';
      return reading('${number(row['day_min'])}～${number(row['day_max'])}');
    case 'usage':
      return reading(number(row['day_usage'] ?? row['day_subtotal']));
    case 'mixed':
      return diagnostics ? '统计类型变化' : '—';
    default:
      return '—';
  }
}

String readableDecimal(Object? value) {
  if (value == null) return '—';
  final text = '$value';
  if (!RegExp(r'^-?\d+\.\d+$').hasMatch(text)) return text;
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
