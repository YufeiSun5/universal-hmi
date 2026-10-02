// Manual CUA entrypoint for an isolated HTTPS loopback fixture only.
// No automated UI actions, embedded credentials, global trust changes, or TLS
// verification bypasses. Production main.dart does not import this file.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/io_client.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const endpoint = String.fromEnvironment('AUTH_CUA_BASE_URL');
  const certificate = String.fromEnvironment('AUTH_CUA_CA_FILE');
  final base = Uri.parse(endpoint);
  if (base.scheme != 'https' ||
      !['localhost', '127.0.0.1', '::1'].contains(base.host) ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      certificate.isEmpty) {
    throw ArgumentError(
      'Provide an HTTPS loopback URL and isolated fixture CA file',
    );
  }
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(await File(certificate).readAsBytes());
  final client = IOClient(HttpClient(context: context));
  runApp(UniversalHmiApp(api: PlatformClient(base, client: client)));
}
