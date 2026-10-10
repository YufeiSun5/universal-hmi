import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/process_files.dart';
import '../../shared/api.dart';
import 'model.dart';

class ProcessMaterialSummary {
  ProcessMaterialSummary(Json data)
    : id = data['id'] as String,
      revision = data['revision'] as int,
      name = data['name'] as String,
      category = data['category'] as String,
      width = data['width'] as int,
      height = data['height'] as int;
  final String id, name, category;
  final int revision, width, height;
}

class ProcessMaterial {
  ProcessMaterial(Json data)
    : summary = ProcessMaterialSummary(data),
      asset = EmbeddedImage.fromJson(
        Map<String, dynamic>.from(data['asset'] as Map),
      );
  final ProcessMaterialSummary summary;
  final EmbeddedImage asset;
}

/// One library per authenticated workspace, shared across station targets.
/// Original PNG bytes are retained. Screens embed copies and survive deletion.
class ProcessMaterialLibrary extends ChangeNotifier {
  ProcessMaterialLibrary(this.api);
  final PlatformApi api;
  List<ProcessMaterialSummary> items = [];
  String? error;
  bool loading = false, loaded = false, _disposed = false;
  final _cache = <String, Future<ProcessMaterial>>{};

  Future<void> refresh() async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await api.request('GET', '/api/v1/process-materials');
      if (_disposed) return;
      items = objects(result['items']).map(ProcessMaterialSummary.new).toList();
      loaded = true;
      final keys = items.map((m) => '${m.id}:${m.revision}').toSet();
      _cache.removeWhere((key, _) => !keys.contains(key));
    } catch (e) {
      if (!_disposed) error = '素材库读取失败：$e';
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<ProcessMaterial> get(ProcessMaterialSummary m) {
    final key = '${m.id}:${m.revision}';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    late final Future<ProcessMaterial> future;
    future = api
        .request('GET', '/api/v1/process-materials/${m.id}')
        .then((data) => ProcessMaterial(data))
        .catchError((Object error, StackTrace trace) {
          if (identical(_cache[key], future)) _cache.remove(key);
          Error.throwWithStackTrace(error, trace);
        });
    _cache[key] = future;
    // At most 32 full-size artwork files (each <= 2 MiB) in the UI cache.
    while (_cache.length > 32) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  Future<ProcessMaterial> upload(
    ProcessFile file,
    String name,
    String category,
  ) async {
    final bytes = file.bytes;
    final png =
        bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71;
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if ((!png && !jpeg) || bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('仅支持不超过 2 MiB 的 PNG/JPEG 图片');
    }
    final id = screenIdentity();
    final data = await api.request(
      'PUT',
      '/api/v1/process-materials/$id',
      body: {
        'schema_version': 1,
        'id': id,
        'revision': 0,
        'name': name.trim(),
        'category': category.trim(),
        'asset': {
          'name': file.name,
          'mime': png ? 'image/png' : 'image/jpeg',
          'data': base64Encode(bytes),
        },
      },
    );
    final result = ProcessMaterial(data);
    if (!_disposed) {
      items = [...items, result.summary]
        ..sort((a, b) => a.name.compareTo(b.name));
      _cache['${result.summary.id}:${result.summary.revision}'] = Future.value(
        result,
      );
      while (_cache.length > 32) {
        _cache.remove(_cache.keys.first);
      }
      notifyListeners();
    }
    return result;
  }

  Future<void> delete(ProcessMaterialSummary m) async {
    await api.request(
      'DELETE',
      '/api/v1/process-materials/${m.id}',
      query: {'revision': m.revision},
    );
    if (_disposed) return;
    items = items.where((item) => item.id != m.id).toList();
    _cache.removeWhere((key, _) => key.startsWith('${m.id}:'));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    super.dispose();
  }
}

class TransparencyGrid extends CustomPainter {
  const TransparencyGrid();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xffffffff),
    );
    final paint = Paint()..color = const Color(0xffe5e7eb);
    for (double y = 0; y < size.height; y += 8) {
      for (double x = 0; x < size.width; x += 8) {
        if (((x / 8).floor() + (y / 8).floor()).isEven) {
          canvas.drawRect(Rect.fromLTWH(x, y, 8, 8), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(TransparencyGrid oldDelegate) => false;
}
