import 'dart:async';
import 'dart:convert';

class TotalReportBridge {
  TotalReportBridge({this.development = false});
  final bool development;
  static const channel = 'hmi-total-reports-v1';
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<dynamic>>{};
  Future<void> Function(String)? send;
  int _sequence = 0;

  void receive(dynamic payload) {
    if (events.isClosed) return;
    dynamic data;
    try {
      data = payload is String ? jsonDecode(payload) : payload;
    } catch (_) {
      return;
    }
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

  Future<void> post(Map<String, dynamic> message) async {
    await send?.call(jsonEncode({'channel': channel, ...message}));
  }

  Future<dynamic> request(String type) async {
    if (send == null) return false;
    final id = 'host-${++_sequence}';
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      await post({'id': id, 'type': type});
      return await completer.future.timeout(const Duration(seconds: 45));
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    send = null;
    events.close();
  }
}
