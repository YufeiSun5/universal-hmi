import '../shared/api.dart';

/// A station owns its interaction state. Dispatch has its own independent scope.
class StationSession {
  int page = 6, offset = 0, boundary = 0;
  String query = '', selectedID = '', quality = '', historyPoint = '';
  String min = '', max = '', from = '', to = '';
  double scroll = 0, trendHeight = 208;
  bool trendVisible = true;
  String operationalView = 'all', sourceFilter = '';
  String watchGrouping = 'source', dashboardUnit = '';
  Set<String> watched = {};
  Set<String> selected = {};
  List<Json> buffer = [], history = [];
  Json stats = {};

  void prune(Set<String> pointIDs, Set<String> historyIDs) {
    selected.removeWhere((id) => !pointIDs.contains(id));
    watched.removeWhere((id) => !pointIDs.contains(id));
    if (!pointIDs.contains(selectedID)) selectedID = '';
    if (!historyIDs.contains(historyPoint)) historyPoint = '';
    buffer.removeWhere((r) => !pointIDs.contains(r['point_id']));
    history.removeWhere((r) => !historyIDs.contains(r['point_id']));
  }
}
