import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/api.dart';

/// One bounded request per visible page, never a full point-library stream.
class EquipmentLiveStatus extends ChangeNotifier {
  EquipmentLiveStatus(this.api);
  final PlatformApi api;
  Timer? timer;
  int epoch = 0;
  bool closed = false;
  Map<String, Object?> revisions = {};
  Map<String, Json> states = {};
  String phase = 'loading';
  void select(List<Json> devices) {
    final token = ++epoch;
    timer?.cancel();
    revisions = {for (final d in devices) d['id'] as String: d['revision']};
    states = {};
    phase = 'loading';
    notifyListeners();
    if (revisions.isNotEmpty) unawaited(refresh(token));
  }

  Future<void> refresh(int token) async {
    try {
      final response = await api
          .request(
            'GET',
            '/api/v1/equipment/status',
            query: {'ids': revisions.keys.join(',')},
          )
          .timeout(const Duration(seconds: 5));
      if (closed || token != epoch) return;
      states = {
        for (final s in objects(response['items']))
          if (revisions[s['id']] == s['revision']) s['id'] as String: s,
      };
      phase = 'unknown';
    } catch (_) {
      if (closed || token != epoch) return;
      states = {};
      phase = 'offline';
    }
    notifyListeners();
    timer = Timer(const Duration(seconds: 2), () => refresh(token));
  }

  Json status(Json device) {
    final result = states[device['id']];
    return result != null && result['revision'] == device['revision']
        ? result
        : {'state': phase};
  }

  @override
  void dispose() {
    closed = true;
    epoch++;
    timer?.cancel();
    super.dispose();
  }
}

class EquipmentStatusBadge extends StatelessWidget {
  const EquipmentStatusBadge({
    super.key,
    required this.live,
    required this.device,
  });
  final EquipmentLiveStatus live;
  final Json device;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: live,
    builder: (_, _) {
      final result = live.status(device);
      final state = result['state'];
      final (label, color) = switch (state) {
        'fault' => ('故障', const Color(0xffc43d45)),
        'running' => ('运行', const Color(0xff12816d)),
        'stopped' => ('停止', const Color(0xff657785)),
        'unconfigured' => ('未配置', const Color(0xff8a97a0)),
        'offline' => ('离线', const Color(0xffad7520)),
        'loading' => ('读取中', const Color(0xff8a97a0)),
        _ => ('未知', const Color(0xffad7520)),
      };
      final reason = switch (result['reason']) {
        'no_running_signal' => '未配置运行变量，无法判断运行或停止',
        'invalid_input' => '变量缺失、质量无效、陈旧或来源离线',
        'unavailable' => '变量未激活、不可用或未授权',
        'invalid_expression' => '状态公式无法计算',
        _ => label,
      };
      return Tooltip(
        message: reason,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .09),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    },
  );
}
