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
  Future<bool>? leaving;
  bool confirmationFailed = false;
  int viewGeneration = 0;
  final leaseClients = <String, String>{};
  bool releasingLeases = false;
  int leaseGeneration = 0;

  Future<void> releaseLease(String path, String client) async {
    try {
      await widget.api.request(
        'POST',
        path,
        body: {'client': client, 'addresses': <String>[]},
      );
    } catch (_) {
      // A disconnected client cannot confirm release. The server's short lease
      // expires independently; never report this best effort as a saved edit.
    }
  }

  Future<void> releaseTrackedLeases() async {
    releasingLeases = true;
    leaseGeneration++;
    final leases = Map<String, String>.from(leaseClients);
    leaseClients.clear();
    await Future.wait(
      leases.entries.map((entry) => releaseLease(entry.key, entry.value)),
    );
  }

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
      releasingLeases = false;
      return;
    }
    if (message['type'] == 'viewError') {
      if (mounted) {
        setState(() {
          confirmationFailed = true;
          error = '报表显示异常，已保存的数据不受影响。请重试确认或重新加载报表。';
        });
      }
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
    final body = message['body'];
    final isLease =
        method == 'POST' &&
        uri.path.endsWith('/locks') &&
        body is Map &&
        body['client'] is String;
    final requestLeaseGeneration = leaseGeneration;
    if (isLease) {
      if (releasingLeases) return;
      leaseClients[uri.path] = body['client'] as String;
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
      // If the renderer was destroyed while its acquire/renew was in flight,
      // release again after that request completes so it cannot revive a lock.
      if (isLease &&
          (releasingLeases ||
              !mounted ||
              requestLeaseGeneration != leaseGeneration)) {
        await releaseLease(uri.path, body['client'] as String);
      }
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

  Future<bool> prepareLeave() {
    final pending = leaving;
    if (pending != null) return pending;
    final result = _prepareLeave();
    leaving = result;
    return result.whenComplete(() => leaving = null);
  }

  Future<bool> _prepareLeave() async {
    if (!ready && !confirmationFailed) return !dirty;
    while (mounted) {
      if (!confirmationFailed) {
        try {
          final alive = await bridge.request(
            'ping',
            timeout: const Duration(seconds: 8),
          );
          if (alive != true) throw StateError('报表未响应');
          final saved = await bridge.request('leave') == true;
          if (saved) {
            dirty = false;
            return true;
          }
          error = '仍有内容未保存，请返回报表核对后重试。';
        } catch (_) {
          error = '报表未响应，无法确认最后的修改是否已保存。';
        }
        if (!mounted) return false;
        setState(() => confirmationFailed = true);
      }
      final choice = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('报表保存尚未确认'),
          content: const Text(
            '可以返回保留当前页面，或重试保存确认。若仍无法响应，可放弃未确认的修改后离开；已保存的数据不会删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'stay'),
              child: const Text('返回报表'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'retry'),
              child: const Text('重试确认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'leave'),
              child: const Text('放弃未确认修改并离开'),
            ),
          ],
        ),
      );
      if (choice == 'leave') {
        unawaited(releaseTrackedLeases());
        return true;
      }
      if (choice != 'retry') return false;
      confirmationFailed = false;
    }
    return false;
  }

  Future<void> reloadReport() async {
    if (!await prepareLeave() || !mounted) return;
    setState(() {
      ready = false;
      dirty = false;
      confirmationFailed = false;
      error = null;
      viewGeneration++;
    });
  }

  @override
  void dispose() {
    unawaited(releaseTrackedLeases());
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
            TextButton(onPressed: reloadReport, child: const Text('重新加载报表')),
            TextButton(
              onPressed: () => setState(() => error = null),
              child: const Text('收起'),
            ),
          ],
        ),
      Expanded(
        key: const ValueKey('report-surface'),
        child: TotalReportView(key: ValueKey(viewGeneration), bridge: bridge),
      ),
    ],
  );
}
