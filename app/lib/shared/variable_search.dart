/// Search syntax shared by variable pickers and lists. Keep wildcard semantics
/// aligned with runtime.discoveryMatcher: alternatives are OR, plain text is a
/// substring, and wildcard patterns match a complete individual field.
class VariableSearch {
  VariableSearch(String query)
    : empty = query.trim().isEmpty,
      patterns = query
          .toLowerCase()
          .split(RegExp(r'[,，\r\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

  final bool empty;
  final List<String> patterns;
  static const hint = '支持 *、?；多个条件用逗号分隔';

  bool matches(String value) {
    if (empty) return true;
    final text = value.toLowerCase();
    return patterns.any((pattern) {
      if (!pattern.contains('*') && !pattern.contains('?')) {
        return text.contains(pattern);
      }
      return _glob(pattern.runes.toList(), text.runes.toList());
    });
  }

  bool matchesPoint(Map<String, dynamic> point) => [
    'name',
    'station',
    'unit',
    'id',
    'source_path',
    'source_id',
    'topic',
  ].any((key) => matches('${point[key] ?? ''}'));

  // Greedy wildcard matching avoids regex backtracking on long paths. A ?
  // consumes one Unicode code point, just like the backend matcher.
  static bool _glob(List<int> pattern, List<int> text) {
    var p = 0, t = 0, star = -1, retry = 0;
    while (t < text.length) {
      if (p < pattern.length && (pattern[p] == 63 || pattern[p] == text[t])) {
        p++;
        t++;
      } else if (p < pattern.length && pattern[p] == 42) {
        star = p++;
        retry = t;
      } else if (star >= 0) {
        p = star + 1;
        t = ++retry;
      } else {
        return false;
      }
    }
    while (p < pattern.length && pattern[p] == 42) {
      p++;
    }
    return p == pattern.length;
  }
}
