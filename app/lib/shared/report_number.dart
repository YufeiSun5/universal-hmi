/// Formats a stored decimal for display without passing it through a double.
/// SQL decimal strings may contain more than 15 digits including trailing zeroes.
/// Rounding affects this string only; source values and exported raw data remain
/// available to the caller.
String reportNumber(Object? value, int decimals) {
  RangeError.checkValueInInterval(decimals, 0, 6, 'decimals');
  if (value == null) return '—';
  final text = '$value';
  final match = RegExp(
    r'^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
  ).firstMatch(text.trim());
  if (match == null) return text;
  final fraction = match[3] ?? '';
  final exponent = int.tryParse(match[4] ?? '0');
  if (exponent == null || exponent.abs() > 1000) return text;
  var units = BigInt.parse('${match[2]}$fraction');
  final shift = fraction.length - exponent - decimals;
  if (shift > 0) {
    final divisor = BigInt.from(10).pow(shift);
    final remainder = units.remainder(divisor);
    units ~/= divisor;
    if (remainder * BigInt.two >= divisor) units += BigInt.one;
  } else if (shift < 0) {
    units *= BigInt.from(10).pow(-shift);
  }
  final digits = units.toString().padLeft(decimals + 1, '0');
  final sign = match[1] == '-' && units != BigInt.zero ? '-' : '';
  if (decimals == 0) return '$sign$digits';
  final split = digits.length - decimals;
  return '$sign${digits.substring(0, split)}.${digits.substring(split)}';
}

String energyOverviewNumber(Object? value, String metric) {
  final parts = reportNumber(value, metric == 'water' ? 1 : 0).split('.');
  final whole = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return parts.length == 1 ? whole : '$whole.${parts.last}';
}

String? energyOverviewTime(Object? value) {
  final utc = value is String ? DateTime.tryParse(value) : null;
  if (utc == null) return null;
  final local = utc.toUtc().add(const Duration(hours: 8)).toIso8601String();
  return local.substring(5, 16).replaceFirst('T', ' ');
}
