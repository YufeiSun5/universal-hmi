import 'package:flutter/material.dart';
import '../platform/backend_management.dart';

class BackendOperationScreen extends StatelessWidget {
  const BackendOperationScreen({
    super.key,
    required this.onReconnect,
    this.error,
  });
  final VoidCallback onReconnect;
  final String? error;
  @override
  Widget build(BuildContext context) {
    final state = backendManagement.state!;
    final phase = state['phase'];
    final failure = switch (state['error_code']) {
      'port_in_use' => '端口被其他程序占用，请核对下方程序与端口。',
      'foreign_project' => '此进程属于其他工程，未结束该进程。',
      'project_identity' => '后台归属核验失败，未结束未确认的进程。',
      'permission_denied' => '权限不足或管理员确认未完成。',
      'certificate_failed' => '证书加载失败。',
      'invalid_address' => '监听地址无效或已不属于本机。',
      'stop_timeout' => '后台停止超时，数据库保持运行，未启动第二个后台。',
      'operation_busy' => '另一个入口正在管理本工程，请等待该操作结束。',
      'start_failed' => '后台启动失败，请核对恢复结果后重试。',
      _ => '',
    };
    final title = switch (phase) {
      'stopping' => '正在停止后台',
      'starting' => '正在启动后台',
      'verifying' => '正在验证',
      'restoring' => '正在恢复原后台',
      'applied' => '后台已生效',
      'stopped' => '后台已停止',
      'failed' => '后台操作失败',
      _ => '正在准备',
    };
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 20),
                if (backendManagement.busy) const LinearProgressIndicator(),
                const SizedBox(height: 16),
                if (failure.isNotEmpty) Text(failure),
                Text('${state['message'] ?? ''}'),
                if (state['recovery'] == 'previous_backend_restored')
                  const Text('原后台健康检查通过；请重新连接后核对内网地址。'),
                if (state['recovery'] == 'restore_failed')
                  const Text('恢复失败，尚未恢复正常访问。工程数据保留。'),
                if (!backendManagement.busy && phase == 'applied')
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('后台重启后原会话会失效。请重新连接并登录；未完成的写入不会自动重放。'),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: backendManagement.busy ? null : onReconnect,
                      child: const Text('重新连接并登录'),
                    ),
                    OutlinedButton(
                      onPressed: backendManagement.busy
                          ? null
                          : () => backendManagement.run('start'),
                      child: const Text('启动后台并重试'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
