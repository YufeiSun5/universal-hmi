import 'dart:async';
import 'dart:convert';

class ProbeBridge {
  static const channel = 'hmi-fortune-probe-v1';
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<dynamic>>{};
  Future<void> Function(String)? send;
  var _sequence = 0;

  void receive(dynamic payload) {
    final data = payload is String ? jsonDecode(payload) : payload;
    if (data is! Map || data['channel'] != channel) return;
    if (data['type'] == 'response') {
      final pending = _pending.remove(data['id']);
      if (data['error'] != null) {
        pending?.completeError(StateError(data['error'].toString()));
      } else {
        pending?.complete(data['result']);
      }
    } else {
      events.add(Map<String, dynamic>.from(data));
    }
  }

  Future<dynamic> request(
    String type, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (send == null) throw StateError('Bridge is not attached');
    final id = '${++_sequence}';
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      await send!(
        jsonEncode({'channel': channel, 'id': id, 'type': type, ...args}),
      );
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    send = null;
    events.close();
  }
}
