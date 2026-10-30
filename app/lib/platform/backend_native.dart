import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/widgets.dart';
import 'backend_process.dart';
import 'backend_endpoint.dart';
import 'exit_barrier.dart';
import 'desktop_lifecycle.dart';
import 'transport_native.dart';

final _backend = LocalBackendProcess(
  isReady: _localReady,
  launch: _launchBackend,
  onError: (error) => debugPrint('Local backend lifecycle: $error'),
);
AppLifecycleListener? _lifecycle;
Directory? _launchDirectory;
int? _launchPid;

Future<bool> _localReady() async {
  final directory = _launchDirectory;
  if (directory != null) {
    try {
      final file = File('${directory.path}/endpoint.json');
      if (_launchPid == null || await file.length() > 4096) return false;
      final endpoint = parseDesktopEndpoint(
        await file.readAsString(),
        _launchPid!,
      );
      if (endpoint == null) return false;
      localBackendUri = endpoint;
    } catch (_) {
      return false;
    }
  }
  return ready(healthUrl: localBackendUri.resolve('health'));
}

Future<bool> ready({
  Uri? healthUrl,
  Duration timeout = const Duration(milliseconds: 600),
}) async {
  final client = newHttpTransport()..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.getUrl(
        healthUrl ?? localBackendUri.resolve('health'),
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
          json['service'] == 'universal-hmi' &&
          json['authentication_required'] == true;
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
  final paths = backendDataPaths(
    executableFolder: folder,
    operatingSystem: Platform.operatingSystem,
    environment: Platform.environment,
    temporaryDirectory: Directory.systemTemp.path,
  );
  _launchDirectory = await Directory.systemTemp.createTemp(
    'universal-hmi-start-',
  );
  _launchPid = null;
  final child = await Process.start(executable.path, [
    '--data-dir',
    paths.dataDirectory,
    '--web-dir',
    paths.webDirectory,
    '--auto-port',
    '--identity',
    '--identity-local-setup',
    '--endpoint-file',
    '${_launchDirectory!.path}/endpoint.json',
  ]);
  _launchPid = child.pid;
  return child;
}

/// Bundle resources and mutable per-user data must remain separate, especially
/// when a macOS app lives in read-only /Applications or a mounted disk image.
({String dataDirectory, String webDirectory}) backendDataPaths({
  required String executableFolder,
  required String operatingSystem,
  required Map<String, String> environment,
  required String temporaryDirectory,
}) {
  final home = environment['HOME'] ?? temporaryDirectory;
  final base = switch (operatingSystem) {
    'windows' => environment['LOCALAPPDATA'] ?? temporaryDirectory,
    'macos' => '$home/Library/Application Support',
    _ => environment['XDG_DATA_HOME'] ?? '$home/.local/share',
  };
  return (
    dataDirectory: environment['HMI_DATA_DIR']?.isNotEmpty == true
        ? environment['HMI_DATA_DIR']!
        : '$base/universal-hmi',
    webDirectory: operatingSystem == 'macos'
        ? '$executableFolder/../Resources/web'
        : '$executableFolder/web',
  );
}

AppLifecycleListener listenForBackendExit(
  LocalBackendProcess backend, {
  Future<void> Function()? drainRendering,
  Future<bool> Function()? canExit,
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
      if (!await (canExit?.call() ?? applicationExitGuards.canExit())) {
        // Clear after the currently assigned future, including synchronous guards.
        scheduleMicrotask(() => exiting = null);
        return AppExitResponse.cancel;
      }
      await backend.stop();
      trace('backend stopped');
      await (drainRendering?.call() ?? drainRenderingForExit(onStage: trace));
      await approveDesktopExit();
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

Future<bool> startLocalBackend({String? initialView, Uri? remote}) async {
  final shared = Platform.environment['HMI_API_BASE_URL'];
  const configured = String.fromEnvironment('API_BASE_URL');
  if (!await initializeDesktopLifecycle(
    initialView: initialView,
    remote: remote != null,
    endpoint:
        remote?.toString() ??
        (shared?.isNotEmpty == true ? shared! : configured),
  )) {
    return false;
  }
  _lifecycle ??= listenForBackendExit(_backend);
  if (remote != null) {
    selectedRemoteBackendUri = remote;
    return true;
  }
  if (shared != null && shared.isNotEmpty) {
    final endpoint = parseSharedBackendEndpoint(shared);
    if (endpoint == null) throw StateError('Invalid shared HMI endpoint');
    localBackendUri = endpoint;
    return true;
  }
  // Rendering shutdown also applies when the backend URL is configured.
  if (configured.isNotEmpty) return true;
  try {
    await _backend.start();
  } finally {
    final directory = _launchDirectory;
    _launchDirectory = null;
    _launchPid = null;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } catch (error) {
        debugPrint('Local backend discovery cleanup: $error');
      }
    }
  }
  return true;
}

void stopLocalBackend() => unawaited(_backend.stop());

Future<void> openConnectionSettings({String? initialView, String? mode}) async {
  await Process.start(Platform.resolvedExecutable, [
    '--connection-settings',
    if (initialView != null) '--view=$initialView',
    ?mode,
  ], mode: ProcessStartMode.detached);
}
