import 'api.dart';

const mcpSettingsPath = '/api/v1/mcp/settings';
const mcpProtocolVersion = '2025-11-25';
const mcpModeLabels = {'off': '关闭', 'read_only': '只读', 'write': '读写'};

class McpSettings {
  const McpSettings(this.data);
  factory McpSettings.parse(Json value) {
    if (!mcpModeLabels.containsKey(value['mode']) ||
        value['revision'] is! int ||
        (value['revision'] as int) < 1 ||
        value['can_change_mode'] is! bool ||
        value['can_enable_write'] is! bool ||
        value['startup_write_allowed'] is! bool ||
        value['available_tool_count'] is! int) {
      throw const FormatException('MCP 状态响应不完整，请刷新重试');
    }
    return McpSettings(value);
  }
  final Json data;
  String get mode => data['mode'] as String;
  int get revision => data['revision'] as int;
  bool get canChange => data['can_change_mode'] == true;
  bool get canEnableWrite => data['can_enable_write'] == true;
  bool get startupWriteAllowed => data['startup_write_allowed'] == true;
  int get toolCount => data['available_tool_count'] as int;
}

class McpConnectionReport {
  const McpConnectionReport(this.protocol, this.tools, this.checkedAt);
  final String protocol;
  final List<String> tools;
  final DateTime checkedAt;
}

/// Fixed-route adapter. It reuses the current workspace session and performs
/// no login, token issuance, configuration change or plant-data mutation.
class McpService {
  const McpService(this.api);
  final PlatformApi api;
  Future<McpSettings> read() async =>
      McpSettings.parse(await api.request('GET', mcpSettingsPath));
  Future<McpSettings> setMode(String mode, int revision) async =>
      McpSettings.parse(
        await api.request(
          'PUT',
          mcpSettingsPath,
          body: {'mode': mode, 'revision': revision},
        ),
      );

  Future<Json> _rpc(int id, String method, Json params) async {
    final envelope = await api.request(
      'POST',
      '/mcp',
      body: {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params},
    );
    if (envelope['jsonrpc'] != '2.0' || envelope['id'] != id) {
      throw const FormatException('MCP 返回了不匹配的协议响应');
    }
    final error = envelope['error'];
    if (error != null) {
      throw const FormatException('MCP 协议请求被拒绝，请刷新状态后重试');
    }
    if (envelope['result'] is! Map) {
      throw const FormatException('MCP 响应缺少结果');
    }
    return Map<String, dynamic>.from(envelope['result'] as Map);
  }

  Future<McpConnectionReport> testConnection() async {
    final initialized = await _rpc(1, 'initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {
        'name': 'universal-hmi-connection-test',
        'version': '1.0.0',
      },
    });
    if (initialized['protocolVersion'] != mcpProtocolVersion) {
      throw const FormatException('MCP 协议版本不兼容');
    }
    await api.request(
      'POST',
      '/mcp',
      body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    );
    final catalog = await _rpc(2, 'tools/list', {});
    final raw = catalog['tools'];
    if (raw is! List || raw.isEmpty || raw.length > 128) {
      throw const FormatException('MCP 工具清单无效或超出上限');
    }
    final names = <String>[];
    bool healthIsReadOnly = false;
    for (final tool in raw) {
      if (tool is! Map ||
          tool['name'] is! String ||
          (tool['name'] as String).isEmpty ||
          names.contains(tool['name'])) {
        throw const FormatException('MCP 工具清单格式错误');
      }
      names.add(tool['name'] as String);
      if (tool['name'] == 'health_get' &&
          tool['annotations'] is Map &&
          (tool['annotations'] as Map)['readOnlyHint'] == true) {
        healthIsReadOnly = true;
      }
    }
    if (!healthIsReadOnly) {
      throw const FormatException('MCP 未提供只读健康检查工具');
    }
    final probe = await _rpc(3, 'tools/call', {
      'name': 'health_get',
      'arguments': <String, dynamic>{},
    });
    final content = probe['structuredContent'];
    if (probe['isError'] != false ||
        content is! Map ||
        content['status'] != 'ok' ||
        content['service'] != 'universal-hmi') {
      throw const FormatException('MCP 只读调用失败，未通过连接测试');
    }
    return McpConnectionReport(mcpProtocolVersion, names, DateTime.now());
  }
}
