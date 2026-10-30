import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;

Uri? selectedRemoteBackendUri;

Uri localBackendUri = Uri.parse('http://127.0.0.1:18080/');

/// A remote project is an HTTPS origin, never a URL containing a resource or
/// credentials. Returning a canonical root also gives it a stable identity.
Uri? parseRemoteBackendEndpoint(String value) {
  if (value.isEmpty || value != value.trim() || value.length > 4096) {
    return null;
  }
  if (!RegExp(
    r'^https://[^/\\?#\s]+/?$',
    caseSensitive: false,
  ).hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    return null;
  }
  return uri.replace(path: '/');
}

Uri backendApiUri() {
  const configured = String.fromEnvironment('API_BASE_URL');
  if (selectedRemoteBackendUri != null) return selectedRemoteBackendUri!;
  return configured.isNotEmpty
      ? Uri.parse(configured)
      : kIsWeb
      ? Uri.base
      : localBackendUri;
}

/// Accept only the endpoint belonging to this launched local server.
Uri? parseDesktopEndpoint(String text, int expectedPid) {
  if (text.length > 4096) return null;
  try {
    final data = jsonDecode(text);
    if (data is! Map || data['pid'] != expectedPid || data['url'] is! String) {
      return null;
    }
    final uri = Uri.parse(data['url'] as String);
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/' ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri;
  } catch (_) {
    return null;
  }
}

/// Two desktop launchers share a single loopback project service.
Uri? parseSharedBackendEndpoint(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.replace(path: '/');
}
