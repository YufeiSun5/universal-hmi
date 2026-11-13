// Input/preview formatting only; the server remains authoritative for stock,
// amounts, versions and permissions. Scaled integers avoid display rounding.
BigInt? materialScaled(String value) {
  if (!RegExp(r'^(0|[1-9][0-9]{0,10})(\.[0-9]{1,4})?$').hasMatch(value)) {
    return null;
  }
  final parts = value.split('.');
  return BigInt.parse(parts.first) * BigInt.from(10000) +
      BigInt.parse((parts.length == 1 ? '' : parts.last).padRight(4, '0'));
}

String materialUnscaled(BigInt value) {
  final sign = value.isNegative ? '-' : '';
  final raw = value.abs().toString().padLeft(5, '0');
  final fraction = raw
      .substring(raw.length - 4)
      .replaceFirst(RegExp(r'0+$'), '');
  return '$sign${raw.substring(0, raw.length - 4)}${fraction.isEmpty ? '' : '.$fraction'}';
}

String? materialNumberError(
  String value, {
  bool positive = false,
  bool optional = false,
}) {
  if (optional && value.isEmpty) return null;
  final n = materialScaled(value);
  if (n == null) return '请输入非负数字，最多11位整数、4位小数';
  if (positive && n <= BigInt.zero) return '数量必须大于0';
  return null;
}
