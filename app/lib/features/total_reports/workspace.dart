import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../platform/total_report_view.dart';
import '../../shared/api.dart';
import 'bridge.dart';

/// Authentication and file I/O stay in the existing platform client. The
/// embedded workbook receives report data, never cookies or bearer tokens.
class TotalReportsWorkspace extends StatefulWidget {
  const TotalReportsWorkspace({
    super.key,
    required this.api,
    this.development = false,
  });
  final PlatformApi api;
  final bool development;
  @override
  State<TotalReportsWorkspace> createState() => TotalReportsWorkspaceState();
}

class TotalReportsWorkspaceState extends State<TotalReportsWorkspace> {
  late final bridge = TotalReportBridge(development: widget.development);
  late final StreamSubscription<Json> subscription;
  bool ready = false, dirty = false;
  String? error;

  @override
  void initState() {
    super.initState();
    subscription = bridge.events.stream.listen(
      (message) => unawaited(receive(message)),
    );
  }

  Future<void> receive(Json message) async {
    if (message['type'] == 'ready') {
      ready = true;
      return;
    }
    if (message['type'] == 'dirty') {
      dirty = message['dirty'] == true;
      return;
    }
    if (message['type'] == 'export') {
      try {
        final data = message['data'] as String;
        if (data.length > 32 * 1024 * 1024) {
          throw const FormatException('导出文件过大');
        }
        await saveFile(
          base64Decode(data),
          (message['name'] as String).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
        );
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      }
      return;
    }
    if (message['type'] != 'api') return;
    final path = message['path']?.toString() ?? '';
    final method = message['method'];
    final uri = Uri.tryParse(path);
    if (uri == null ||
        uri.hasAuthority ||
        uri.hasFragment ||
        !RegExp(
          r'^/api/v1/total-reports(?:/[a-z0-9_-]+)*$',
        ).hasMatch(uri.path) ||
        (method != 'GET' && method != 'POST')) {
      await bridge.post({
        'type': 'apiResult',
        'id': message['id'],
        'status': 400,
        'error': '报表请求无效',
      });
      return;
    }
    try {
      final response = await widget.api.request(
        method as String,
        uri.path,
        query: uri.queryParameters.isEmpty
            ? null
            : Map<String, dynamic>.from(uri.queryParameters),
        body: message['body'],
      );
      if (mounted) {
        await bridge.post({
          'type': 'apiResult',
          'id': message['id'],
          'result': response,
        });
      }
    } catch (e) {
      if (mounted) {
        await bridge.post({
          'type': 'apiResult',
          'id': message['id'],
          'error': '$e',
          'status': e is PlatformRequestException ? e.statusCode : 0,
        });
      }
    }
  }

  Future<bool> prepareLeave() async {
    if (!ready) return !dirty;
    try {
      final saved = await bridge.request('leave') == true;
      if (!saved && mounted) setState(() => error = '仍有内容未保存，请在报表中重试后再离开。');
      return saved;
    } catch (e) {
      if (mounted) setState(() => error = '报表未确认保存，请重试：$e');
      return false;
    }
  }

  @override
  void dispose() {
    subscription.cancel();
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (error != null)
        MaterialBanner(
          content: Text(error!),
          actions: [
            TextButton(
              onPressed: () => setState(() => error = null),
              child: const Text('收起'),
            ),
          ],
        ),
      Expanded(child: TotalReportView(bridge: bridge)),
    ],
  );
}
