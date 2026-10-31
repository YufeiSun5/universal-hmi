import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

String? _pem;
String? _origin;
void configureRemoteTrust(String? pem, {String? origin}) {
  _pem = pem;
  _origin = origin;
}

HttpClient newHttpTransport() {
  if (_pem == null) return HttpClient();
  final context = SecurityContext(withTrustedRoots: false);
  context.setTrustedCertificatesBytes(utf8.encode(_pem!));
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(_pem!);
  final origin = _origin;
  if (match == null || origin == null) {
    throw const FormatException('缺少有效证书或地址');
  }
  final expected = sha256.convert(
    base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
  );
  final client = HttpClient(context: context);
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (uri.scheme == 'http' && uri.host == '127.0.0.1') {
      return Socket.startConnect(uri.host, uri.port);
    }
    if (uri.scheme != 'https' || uri.origin != origin) {
      throw StateError('远程连接地址与证书不匹配');
    }
    final task = await SecureSocket.startConnect(
      uri.host,
      uri.port,
      context: context,
    );
    final verified = task.socket.then<Socket>((socket) {
      final cert = socket.peerCertificate;
      if (cert == null || sha256.convert(cert.der) != expected) {
        socket.destroy();
        throw const HandshakeException('远程证书指纹不匹配');
      }
      return socket;
    });
    return ConnectionTask.fromSocket<Socket>(verified, task.cancel);
  };
  return client;
}

http.Client newTransport() => IOClient(newHttpTransport());
