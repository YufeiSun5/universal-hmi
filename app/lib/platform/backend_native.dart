import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/widgets.dart';
import 'backend_process.dart';
import 'exit_barrier.dart';

final _backend = LocalBackendProcess(
  isReady: ready,
  launch: _launchBackend,
  onError: (error) => debugPrint('Local backend lifecycle: $error'),
);
AppLifecycleListener? _lifecycle;

Future<bool> ready({
  Uri? healthUrl,
  Duration timeout = const Duration(milliseconds: 600),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.getUrl(
        healthUrl ?? Uri.parse('http://127.0.0.1:18080/health'),
      );
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return false;
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 8192) return false;
        bytes.addAll(chunk);
      }
      final json = jsonDecode(utf8.decode(bytes));
      return json is Map &&
          json['status'] == 'ok' &&
          json['service'] == 'universal-hmi';
    })().timeout(timeout);
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<Process?> _launchBackend() async {
  final folder = File(Platform.resolvedExecutable).parent.path;
  final executable = File(
    '$folder/universal-hmi-server${Platform.isWindows ? '.exe' : ''}',
  );
  if (!await executable.exists()) return null;
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  final base = Platform.isWindows
      ? (Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path)
      : (Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share');
  return Process.start(executable.path, [
    '--data-dir',
    '$base/universal-hmi',
    '--web-dir',
    '$folder/web',
  ]);
}

AppLifecycleListener listenForBackendExit(
  LocalBackendProcess backend, {
  Future<void> Function()? drainRendering,
}) {
  Future<AppExitResponse>? exiting;
  void trace(String stage) {
    if (Platform.environment.containsKey('HMI_LIFECYCLE_TRACE')) {
      debugPrintSynchronously('HMI lifecycle: $stage');
    }
  }

  Future<AppExitResponse> requestExit() async {
    trace(
      'exit requested; first_frame_rasterized='
      '${WidgetsBinding.instance.firstFrameRasterized}',
    );
    try {
      await backend.stop();
      trace('backend stopped');
      await (drainRendering?.call() ?? drainRenderingForExit(onStage: trace));
      return AppExitResponse.exit;
    } catch (error) {
      // An error response on the platform channel makes Flutter quit anyway.
      // Explicitly cancel instead, preserving the failure for a retry/diagnosis.
      debugPrintSynchronously('HMI lifecycle: exit cancelled: $error');
      exiting = null;
      return AppExitResponse.cancel;
    }
  }

  return AppLifecycleListener(
    onExitRequested: () => exiting ??= requestExit(),
    onDetach: () => unawaited(backend.stop()),
  );
}

Future<void> startLocalBackend() async {
  // Rendering shutdown also applies when the backend URL is configured.
  _lifecycle ??= listenForBackendExit(_backend);
  const configured = String.fromEnvironment('API_BASE_URL');
  if (configured.isNotEmpty) return;
  await _backend.start();
}

void stopLocalBackend() => unawaited(_backend.stop());
