import 'dart:ui' show AppExitType;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef ApplicationExitGuard = Future<bool> Function();

/// Workspace lifetime owns its guard; retiring a workspace cannot unregister a
/// newer workspace's guard during an authentication/navigator replacement.
class ApplicationExitGuards {
  final _guards = <Object, ApplicationExitGuard>{};

  VoidCallback register(ApplicationExitGuard guard) {
    final key = Object();
    _guards[key] = guard;
    return () => _guards.remove(key);
  }

  Future<bool> canExit() async {
    for (final entry in _guards.entries.toList()) {
      if (_guards[entry.key] == entry.value && !await entry.value()) {
        return false;
      }
    }
    return true;
  }
}

final applicationExitGuards = ApplicationExitGuards();
const desktopLifecycleChannel = MethodChannel('universal_hmi/desktop');
bool _desktopInitialized = false;

Future<void> approveDesktopExit() async {
  if (_desktopInitialized) {
    await desktopLifecycleChannel.invokeMethod<void>('approveExit');
  }
}

String desktopRole(String? initialView) =>
    const ['runtime', 'gis', 'process', 'equipment'].contains(initialView)
    ? 'runtime'
    : 'developer';

String desktopEndpointIdentity(String endpoint) {
  if (endpoint.isEmpty) return '';
  final uri = Uri.parse(endpoint);
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.isEmpty ? '/' : uri.normalizePath().path,
  ).toString();
}

/// Runs before backend startup and the first app frame. Web/Linux retain their
/// existing lifecycle; only Windows owns a native single-instance/tray channel.
Future<bool> initializeDesktopLifecycle({
  String? initialView,
  String endpoint = '',
  bool remote = false,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return true;
  desktopLifecycleChannel.setMethodCallHandler((call) async {
    if (call.method != 'requestExit') throw MissingPluginException();
    await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
  });
  _desktopInitialized =
      await desktopLifecycleChannel.invokeMethod<bool>('initialize', {
        'role': desktopRole(initialView),
        'endpoint': desktopEndpointIdentity(endpoint),
        if (remote) 'remote': true,
      }) ??
      false;
  return _desktopInitialized;
}
