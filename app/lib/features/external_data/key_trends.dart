import 'dart:async';
import 'package:flutter/material.dart';
import '../../platform/total_report_view.dart';
import '../../shared/api.dart';
import '../total_reports/bridge.dart';

/// The renderer receives data only. It cannot choose an API path, screen,
/// request mode or credentials; the existing hourly screen owns authorization.
class KeyTrendsWorkspace extends StatefulWidget {
  const KeyTrendsWorkspace({
    super.key,
    required this.api,
    required this.screen,
  });
  final PlatformApi api;
  final Json screen;
  @override
  State<KeyTrendsWorkspace> createState() => _KeyTrendsWorkspaceState();
}

class _KeyTrendsWorkspaceState extends State<KeyTrendsWorkspace> {
  final bridge = TotalReportBridge(channelName: 'hmi-key-trends-v1');
  StreamSubscription<Json>? subscription;
  Timer? loadTimer;
  bool ready = false, requesting = false;
  String? error;
  int instance = 0;
  String get path =>
      '/api/v1/external/screens/${Uri.encodeComponent('${widget.screen['query_id'] ?? widget.screen['id']}')}';

  @override
  void initState() {
    super.initState();
    subscription = bridge.events.stream.listen(receive);
    watchLoad();
  }

  void watchLoad() {
    loadTimer?.cancel();
    loadTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !ready) setState(() => error = '曲线画面加载失败，请重新加载');
    });
  }

  Future<void> receive(Json message) async {
    if (message['type'] == 'ready') {
      loadTimer?.cancel();
      if (mounted) {
        setState(() {
          ready = true;
          error = null;
        });
      }
      return;
    }
    if (message['type'] == 'viewError') {
      if (mounted) setState(() => error = '曲线画面加载失败，请重新加载');
      return;
    }
    final type = message['type'];
    if (type != 'stations' && type != 'query') return;
    final id = message['id'];
    if (id is! String || id.length > 80) return;
    if (requesting) {
      await bridge.post({'type': 'result', 'id': id, 'error': '查询正在进行，请稍候'});
      return;
    }
    requesting = true;
    final generation = instance;
    try {
      Json result;
      if (type == 'stations') {
        result = await widget.api.request('GET', '$path/stations');
      } else {
        final stations = message['stations'];
        if (stations is! List ||
            stations.isEmpty ||
            stations.length > 256 ||
            stations.any((v) => v is! String) ||
            message['from'] is! String ||
            message['to'] is! String) {
          throw const FormatException('请选择站区和有效日期');
        }
        result = await widget.api.request(
          'POST',
          '$path/query',
          body: {
            'mode': 'key_trends',
            'stations': stations,
            'from': message['from'],
            'to': message['to'],
          },
        );
      }
      if (mounted && instance == generation) {
        await bridge.post({'type': 'result', 'id': id, 'data': result});
      }
    } catch (e) {
      if (mounted && instance == generation) {
        await bridge.post({'type': 'result', 'id': id, 'error': '$e'});
      }
    } finally {
      if (instance == generation) requesting = false;
    }
  }

  @override
  void dispose() {
    loadTimer?.cancel();
    subscription?.cancel();
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: TotalReportView(
          key: ValueKey(instance),
          bridge: bridge,
          resourceDirectory: 'key-trends',
          title: '重点数据曲线',
        ),
      ),
      if (!ready || error != null)
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(error!),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              instance++;
                              ready = false;
                              requesting = false;
                              error = null;
                            });
                            watchLoad();
                          },
                          child: const Text('重新加载'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
    ],
  );
}
