import 'package:flutter/material.dart';
import '../platform/autostart.dart';
import '../shared/api.dart';
import 'security_layout.dart';

class AutostartSettings extends StatefulWidget {
  const AutostartSettings({super.key, required this.api});
  final PlatformApi api;
  @override
  State<AutostartSettings> createState() => _AutostartSettingsState();
}

class _AutostartSettingsState extends State<AutostartSettings> {
  Json? state;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    read();
  }

  Future<void> read() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await readAutostart();
      if (mounted) setState(() => state = next);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          state = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> configure() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final allowed = await widget.api.request(
        'POST',
        '/api/v1/security/network-access',
        body: {'action': 'authorize_startup'},
      );
      if (allowed['authorized'] != true) throw StateError('当前账号没有本机自启动配置权限');
      await configureAutostart();
      final next = await readAutostart();
      if (mounted) setState(() => state = next);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          state = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SecuritySection(
    title: '开机与登录自启动',
    description: '后台开机启动可在无人登录Windows时采集和提供网页服务；运行界面在登录Windows后打开。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state != null) ...[
          Text('后台开机启动：${state!['boot_enabled'] == true ? '已开启' : '已关闭'}'),
          const SizedBox(height: 8),
          Text('登录后打开运行界面：${state!['login_enabled'] == true ? '已开启' : '已关闭'}'),
          if (state!['last_run'] != '')
            Text('上次任务：${state!['last_run']} · 结果码 ${state!['last_result']}'),
        ],
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : configure,
              child: const Text('配置本机自启动'),
            ),
            TextButton(
              onPressed: busy ? null : read,
              child: const Text('重新读取自启动状态'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '首次启用后台任务需Windows管理员确认，并在配置窗口填写Windows账号密码（不是PIN）。密码由Windows任务计划程序管理。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}
