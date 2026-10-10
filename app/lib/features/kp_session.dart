import 'package:flutter/material.dart';

class KpSessionScreen extends StatelessWidget {
  const KpSessionScreen({
    super.key,
    required this.state,
    this.error,
    required this.onRetry,
  });
  final String state;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = switch (state) {
      'connecting' => '正在接入工作区……',
      'logout_submitting' => '已停止业务访问，正在提交退出请求……',
      'logout_requested' => '已退出业务，正在等待 KP 返回登录页',
      'logout_unconfirmed' => '已停止业务访问，退出请求尚未确认',
      'closed' => '已退出，请返回 KP 登录',
      'expired' => 'KP 登录关联已失效，请重新登录',
      'unavailable' => '连接中断，已暂停业务访问',
      _ => '请从 KP 登录后进入本页面',
    };
    final retry = state == 'unavailable' || state == 'logout_unconfirmed';
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.account_circle_outlined, size: 32),
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const Key('kp-session-message'),
                  textAlign: TextAlign.center,
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, textAlign: TextAlign.center),
                ],
                if (retry) ...[
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: onRetry,
                    child: Text(
                      state == 'logout_unconfirmed' ? '重试退出' : '重新连接',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
