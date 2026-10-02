import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;
List<Json> objects(dynamic value) => (value as List? ?? [])
    .map((v) => Map<String, dynamic>.from(v as Map))
    .toList();

/// Immutable runtime views avoid cloning each of the 15,000 snapshot maps.
/// Editable configurations continue to use objects() for defensive copies.
List<Json> snapshotObjects(dynamic value) => (value as List? ?? const [])
    .map((v) => v is Json ? v : Map<String, dynamic>.from(v as Map))
    .toList(growable: false);
Json _decodeObject(Uint8List bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
Future<Json> decodeResponseObject(Uint8List bytes) async {
  if (!kIsWeb && bytes.length >= 256 * 1024) {
    return compute(_decodeObject, bytes, debugLabel: 'HMI JSON response');
  }
  return _decodeObject(bytes);
}

abstract interface class PlatformApi {
  Future<Json> request(String method, String path, {Object? body, Json? query});
  Future<Json> upload(String name, Uint8List bytes);
  Future<Uint8List> download(String id);
  void close();
}

class PlatformClient implements PlatformApi {
  PlatformClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();
  final Uri base;
  final http.Client _client;
  Uri uri(String path, Json? query) => base
      .resolve(path)
      .replace(queryParameters: query?.map((k, v) => MapEntry(k, '$v')));
  Future<http.Response> checked(Future<http.Response> task) async {
    final response = await task.timeout(const Duration(seconds: 35));
    if (response.statusCode >= 400) {
      String message = '请求失败 (${response.statusCode})';
      try {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
        message = ((data['error'] as Json?)?['message'] ?? message).toString();
      } catch (_) {}
      throw Exception(message);
    }
    return response;
  }

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final request = http.Request(method, uri(path, query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await checked(
      _client.send(request).then(http.Response.fromStream),
    );
    return decodeResponseObject(response.bodyBytes);
  }

  @override
  Future<Json> upload(String name, Uint8List bytes) async {
    final request = http.MultipartRequest(
      'POST',
      uri('/api/v1/import/upload', null),
    );
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: name),
    );
    final response = await checked(
      _client.send(request).then(http.Response.fromStream),
    );
    return decodeResponseObject(response.bodyBytes);
  }

  @override
  Future<Uint8List> download(String id) async => (await checked(
    _client.get(uri('/api/v1/jobs/$id/file', null)),
  )).bodyBytes;
  @override
  void close() => _client.close();
}

String number(dynamic value) {
  if (value == null) return '—';
  if (value is num) {
    return value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return '$value';
}

String clock(dynamic value) {
  final date = DateTime.tryParse('$value');
  if (date == null || date.year < 2000) return '—';
  return date
      .toLocal()
      .toIso8601String()
      .replaceFirst('T', ' ')
      .substring(0, 19);
}
