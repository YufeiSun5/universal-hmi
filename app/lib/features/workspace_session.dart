import '../shared/api.dart';

/// A station owns its interaction state. Dispatch has its own independent scope.
class StationSession {
  int page = 6, offset = 0, boundary = 0;
  String query = '', selectedID = '', quality = '', historyPoint = '';
  String min = '', max = '', from = '', to = '';
  double scroll = 0, matrixScroll = 0, trendHeight = 208;
  bool trendVisible = false, matrixCompact = true;
  String monitorLayout = 'matrix';
  String operationalView = 'all', sourceFilter = '';
  String watchGrouping = 'source', dashboardUnit = '';
  Set<String> watched = {};
  Set<String> selected = {};
  List<Json> buffer = [], history = [];
  Json stats = {}, historySeries = {}, appliedHistoryQuery = {};
  Set<String> historyPoints = {};
  String historyPreset = '1h', historyUnit = '';
  bool historyLoaded = false;

  void prune(Set<String> pointIDs, Set<String> historyIDs) {
    selected.removeWhere((id) => !pointIDs.contains(id));
    watched.removeWhere((id) => !pointIDs.contains(id));
    if (!pointIDs.contains(selectedID)) selectedID = '';
    if (!historyIDs.contains(historyPoint)) historyPoint = '';
    historyPoints.removeWhere((id) => !historyIDs.contains(id));
    buffer.removeWhere((r) => !pointIDs.contains(r['point_id']));
    history.removeWhere((r) => !historyIDs.contains(r['point_id']));
  }
}
