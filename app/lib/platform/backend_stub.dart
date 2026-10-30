Future<bool> startLocalBackend({String? initialView, Uri? remote}) async =>
    true;
Future<bool> ready({
  Uri? healthUrl,
  Duration timeout = const Duration(milliseconds: 600),
}) async => true;
void stopLocalBackend() {}
Future<void> openConnectionSettings({
  String? initialView,
  String? mode,
}) async {}
