import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/mcp_api.dart';

/// The parent owns this session-scoped client and removes the entire panel when
/// its workspace retires. This widget never retains a later session or retries a
/// mode mutation, including after timeouts and CSRF/session errors.
class McpSettingsPanel extends StatefulWidget {
  const McpSettingsPanel({
    super.key,
    required this.api,
    required this.endpoint,
  });
  final PlatformApi api;
  final String endpoint;
  @override
  State<McpSettingsPanel> createState() => _McpSettingsPanelState();
}

class _McpSettingsPanelState extends State<McpSettingsPanel> {
  McpSettings? settings;
  McpConnectionReport? report;
  String selected = 'read_only', progress = '', error = '';
  bool busy = false;
  int generation = 0;
  McpService get service => McpService(widget.api);

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant McpSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      generation++;
      settings = null;
      report = null;
      busy = false;
      refresh();
    }
  }

  bool current(int ticket) => mounted && generation == ticket;

  String describeError(Object e) {
    if (e is PlatformRequestException) {
      if (e.code == 'mcp_disabled') return 'MCP 已关闭；可先应用只读模式，再测试连接';
      if (e.statusCode == 401 || e.code == 'csrf_rejected') {
        return '会话已过期或已变更，请重新登录';
      }
      if (e.statusCode == 409) return '模式已被其他窗口修改，请刷新后重新选择';
      if (e.statusCode == 429) return 'MCP 正忙，请稍后再测试';
      if (e.statusCode == 403) return '没有足够权限，或服务器启动时未开放 MCP 写入';
      return '连接失败（HTTP ${e.statusCode}），请检查服务状态后重试';
    }
    if (e is FormatException) return e.message;
    return '无法完成请求，请检查服务连接。若刚应用模式，请先刷新核对结果';
  }

  Future<void> refresh() async {
    if (busy) return;
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      progress = '读取 MCP 状态…';
      report = null;
    });
    try {
      final next = await service.read();
      if (!current(ticket)) return;
      setState(() {
        settings = next;
        selected = next.mode;
      });
    } catch (e) {
      if (current(ticket)) {
        setState(() {
          error = describeError(e);
          settings = null;
        });
      }
    } finally {
      if (current(ticket)) {
        setState(() {
          busy = false;
          progress = '';
        });
      }
    }
  }

  Future<void> apply() async {
    final before = settings;
    if (busy ||
        before == null ||
        !before.canChange ||
        selected == before.mode) {
      return;
    }
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      report = null;
      progress = '应用 MCP 模式…';
    });
    try {
      final next = await service.setMode(selected, before.revision);
      if (!current(ticket)) return;
      setState(() {
        settings = next;
        selected = next.mode;
      });
    } catch (e) {
      if (current(ticket)) {
        setState(() {
          error = describeError(e);
          settings = null;
        });
      }
    } finally {
      if (current(ticket)) {
        setState(() {
          busy = false;
          progress = '';
        });
      }
    }
  }

  Future<void> testConnection() async {
    if (busy) return;
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      report = null;
      progress = '测试初始化、工具清单和只读调用…';
    });
    try {
      final next = await service.read();
      if (!current(ticket)) return;
      setState(() {
        settings = next;
        selected = next.mode;
      });
      // Test the actual /mcp even when disabled, so the reported error is the
      // server response, never a simulated UI result or an automatic enable.
      final result = await service.testConnection();
      if (!current(ticket)) return;
      setState(() => report = result);
    } catch (e) {
      if (current(ticket)) setState(() => error = describeError(e));
    } finally {
      if (current(ticket)) {
        setState(() {
          busy = false;
          progress = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = settings;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'MCP 模式与连接',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('连接当前服务的工具接口，沿用当前账户与会话权限。测试仅检查连接与只读健康信息。'),
        const SizedBox(height: 18),
        SelectableText(
          '服务端点：${state?.data['endpoint_url'] ?? widget.endpoint}',
          key: const Key('mcp-endpoint'),
        ),
        const SizedBox(height: 8),
        Text(
          '当前模式：${state == null ? '未确认' : mcpModeLabels[state.mode]}',
          key: const Key('mcp-current-mode'),
        ),
        if (state != null) ...[
          const SizedBox(height: 8),
          Text('当前会话可用 ${state.toolCount} 个工具 · 协议 $mcpProtocolVersion'),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('mcp-mode-${state.revision}-$selected'),
                  initialValue: selected,
                  decoration: const InputDecoration(labelText: '选择运行模式'),
                  items: mcpModeLabels.entries
                      .map(
                        (entry) => DropdownMenuItem(
                          value: entry.key,
                          enabled: entry.key != 'write' || state.canEnableWrite,
                          child: Text(entry.value),
                        ),
                      )
                      .toList(),
                  onChanged: busy || !state.canChange
                      ? null
                      : (value) {
                          if (value != null) setState(() => selected = value);
                        },
                ),
              ),
              FilledButton(
                key: const Key('mcp-apply'),
                onPressed: busy || !state.canChange || selected == state.mode
                    ? null
                    : apply,
                child: const Text('应用模式'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            !state.canChange
                ? '当前账户只读，可查看状态和测试，不能切换模式。'
                : !state.startupWriteAllowed
                ? '服务器启动时未开放 MCP 写入；此处只能切换关闭或只读。'
                : '读写模式仅向已有写入权限的账户开放修改工具；应用模式不会执行设备下设。',
          ),
        ],
        const SizedBox(height: 10),
        const Text(
          '模式对当前服务的所有 MCP 客户端生效，重启后恢复只读。关闭或只读均不会撤销已经受理的设备命令或后台动作；本页不创建或保存凭据。',
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('mcp-refresh'),
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('刷新状态'),
            ),
            FilledButton.icon(
              key: const Key('mcp-test'),
              onPressed: busy ? null : testConnection,
              icon: const Icon(Icons.network_check, size: 17),
              label: const Text('测试连接'),
            ),
          ],
        ),
        if (busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(progress),
        ],
        if (error.isNotEmpty) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              key: const Key('mcp-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        if (report case final result?) ...[
          const SizedBox(height: 18),
          Semantics(
            liveRegion: true,
            child: Text(
              '连接测试通过 · ${clock(result.checkedAt.toIso8601String())}',
              key: const Key('mcp-test-result'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          Text('初始化成功 · 工具清单 ${result.tools.length} 项 · health_get 只读调用成功'),
          const SizedBox(height: 8),
          SelectableText(result.tools.join('、')),
        ],
        const SizedBox(height: 18),
        const Text(
          '此测试验证当前应用到同一服务器的 MCP 连接。第三方客户端仍需兼容自定义认证请求头；仅支持 OAuth 自动发现的客户端不能直接接入。',
        ),
      ],
    );
  }
}
