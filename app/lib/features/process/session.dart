import '../../shared/api.dart';
import 'controller.dart';
import 'model.dart';

/// A station owns one editor draft even when it is viewed in multiple hosts.
class ProcessSession {
  ProcessSession(this.station)
    : controller = ProcessController(ScreenDocument.empty(station));
  final String station;
  final ProcessController controller;
  List<Json> screens = [];
  bool loaded = false, disposed = false;
  Future<void>? _loading;
  Future<void> ensureLoaded(PlatformApi api) {
    if (loaded || disposed) return Future.value();
    return _loading ??= _load(api).whenComplete(() => _loading = null);
  }

  Future<void> _load(PlatformApi api) async {
    final initial = controller.document;
    final result = await api.request(
      'GET',
      '/api/v1/screens',
      query: {'station': station},
    );
    if (disposed) return;
    screens = objects(result['items']);
    // Do not replace a draft created or edited while the request was in flight.
    if (screens.isNotEmpty &&
        identical(controller.document, initial) &&
        !(controller.dirty && initial.nodes.isNotEmpty)) {
      final result = await api.request(
        'GET',
        '/api/v1/screens/${screens.first['id']}',
      );
      if (disposed) return;
      final next = ScreenDocument.fromJson(result);
      if (next.station != station) throw const FormatException('画面不属于当前站点');
      if (identical(controller.document, initial)) controller.open(next);
    }
    loaded = true;
  }

  void dispose() {
    disposed = true;
    controller.dispose();
  }
}
