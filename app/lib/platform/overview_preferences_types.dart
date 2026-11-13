class OverviewPosition {
  const OverviewPosition({this.row = '', this.group = '', this.table = false});
  final String row, group;
  final bool table;
}

abstract interface class OverviewPreferenceStore {
  Future<OverviewPosition> load(String username);
  Future<void> save(String username, OverviewPosition position);
}
