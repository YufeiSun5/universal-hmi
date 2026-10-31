import 'dart:async';
import 'dart:convert';

/// Decode SSE at line boundaries, including split UTF-8/network chunks.
/// Delta streams begin with a reset; gaps fail closed and require a reconnect.
Stream<Map<String, dynamic>> decodeRuntimeEvents(
  Stream<List<int>> bytes, {
  void Function()? onSessionExpired,
}) async* {
  var event = '';
  final data = <String>[];
  var size = 0;
  final merger = RuntimeDeltaMerger();
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (event == 'session-expired') {
        // Retire authorization before waiting for a streaming transport to cancel.
        onSessionExpired?.call();
        throw const RuntimeSessionExpired();
      }
      if (event == 'runtime' && data.isNotEmpty) {
        yield Map<String, dynamic>.from(jsonDecode(data.join('\n')) as Map);
      }
      if (event == 'runtime-delta' && data.isNotEmpty) {
        yield merger.accept(
          Map<String, dynamic>.from(jsonDecode(data.join('\n')) as Map),
        );
      }
      event = '';
      data.clear();
      size = 0;
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      size += line.length;
      if (size > 32 * 1024 * 1024) throw const FormatException('实时数据超过大小限制');
      data.add(line.substring(5).trimLeft());
    }
  }
}

class RuntimeDeltaMerger {
  String? _epoch;
  int _sequence = 0;
  String? _version;
  Map<String, dynamic> _meta = {};
  final _values = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> _snapshot = const [];

  Map<String, dynamic> accept(Map<String, dynamic> frame) {
    final reset = frame['kind'] == 'reset';
    final epoch = frame['epoch'];
    final sequence = frame['sequence'];
    final version = frame['version'];
    if (epoch is! String ||
        epoch.isEmpty ||
        sequence is! int ||
        sequence != _sequence + 1 ||
        version is! String ||
        (_epoch != null && epoch != _epoch) ||
        (!reset &&
            (_epoch == null ||
                version != _version ||
                frame['kind'] != 'delta')) ||
        (reset && frame['meta'] is! Map)) {
      throw const FormatException('实时数据序列不连续，正在重新同步');
    }
    if (reset) _values.clear();
    for (final raw in frame['values'] as List) {
      final row = Map<String, dynamic>.from(raw as Map);
      final id = row['point_id'] as String;
      _values[id] = Map<String, dynamic>.unmodifiable({
        ...?_values[id],
        ...row,
      });
    }
    for (final id in frame['removed'] as List) {
      _values.remove(id);
    }
    if (frame['meta'] case final Map meta) {
      _meta = Map<String, dynamic>.from(meta);
    }
    _epoch = epoch;
    _sequence = sequence;
    _version = version;
    if (reset ||
        (frame['values'] as List).isNotEmpty ||
        (frame['removed'] as List).isNotEmpty) {
      _snapshot = List.unmodifiable(_values.values);
    }
    return {..._meta, 'version': version, 'values': _snapshot};
  }
}

class RuntimeSessionExpired implements Exception {
  const RuntimeSessionExpired();
}
