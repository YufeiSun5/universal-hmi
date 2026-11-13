import '../../shared/api.dart';

/// An absent choice uses the customer's desktop default. An explicit choice
/// survives renaming and is shared by Web and Windows through the config.
bool overviewDesktopVisible(Json column) {
  final explicit = column['desktop_visible'];
  if (explicit is bool) return explicit;
  final name = '${column['name'] ?? ''}';
  final group = '${column['group'] ?? ''}';
  if (name.contains('泵') && name.contains('出口压力')) return false;
  final pump =
      group.contains('泵') ||
      name.contains('泵') ||
      name.startsWith('循') ||
      name.startsWith('补水');
  return !(pump && name.contains('电流'));
}

List<Json> overviewClientColumns(List<Json> columns, {required bool phone}) =>
    phone ? columns : columns.where(overviewDesktopVisible).toList();
