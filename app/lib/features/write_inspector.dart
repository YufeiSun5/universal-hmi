import 'dart:async';
import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/theme.dart';

String commandStateLabel(String state) => switch (state) {
  'accepted' => '已接受 · 等待发送',
  'sent' => '已发送 · 等待设备应答',
  'acknowledged' => '设备已应答 · 等待读回',
  'readback_confirmed' => '新鲜读回已确认',
  'failed' => '下设失败',
  'unknown' => '结果未知 · 请核对',
  _ => '尚未下设',
};

class WriteInspector extends StatefulWidget {
  const WriteInspector({
    super.key,
    required this.api,
    required this.point,
    required this.sample,
    required this.online,
    required this.version,
    required this.onEdit,
    required this.onRefresh,
    required this.commands,
  });
  final PlatformApi api;
  final Json point, sample;
  final bool online;
  final String version;
  final VoidCallback onEdit, onRefresh;
  final Map<String, Json> commands;
  @override
  State<WriteInspector> createState() => _WriteInspectorState();
}

class _WriteInspectorState extends State<WriteInspector> {
  final input = TextEditingController();
  Json? capability, result;
  String? error;
  bool loading = true, sending = false, checking = false, boolValue = false;
  Timer? timer;
  DateTime? pollingStarted;
  String get id => widget.point['id'].toString();
  String get type =>
      (capability?['data_type'] ?? widget.point['data_type'] ?? '').toString();
  bool get unresolved =>
      [
        'accepted',
        'sent',
        'acknowledged',
        'unknown',
      ].contains(result?['state']) &&
      !(result?['state'] == 'sent' &&
          (result?['ack_state'] == 'unsupported' ||
              capability?['protocol'] == 'generic')) &&
      !(result?['state'] == 'acknowledged' &&
          result?['readback_state'] == 'unconfirmed');
  bool get canWrite =>
      widget.online &&
      capability?['writable'] == true &&
      widget.point['rw_mode'] != 'R' &&
      widget.point['writable'] == true &&
      ['FLOAT', 'INT', 'BOOL'].contains(type);

  @override
  void initState() {
    super.initState();
    final value = widget.sample['value'];
    input.text = value == null ? '' : number(value);
    boolValue = value == true || value == 1;
    result = widget.commands[id];
    if (result != null) pollingStarted = DateTime.now();
    loadCapability();
    timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (unresolved &&
          pollingStarted != null &&
          DateTime.now().difference(pollingStarted!) >=
              const Duration(seconds: 45) &&
          error == null) {
        setState(() => error = '等待已超过 45 秒，可手动核对；关闭面板不会撤销命令');
      }
      if (unresolved &&
          widget.online &&
          result?['state'] != 'unknown' &&
          pollingStarted != null &&
          DateTime.now().difference(pollingStarted!) <
              const Duration(seconds: 45)) {
        reconcile();
      }
    });
  }

  @override
  void didUpdateWidget(WriteInspector old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version ||
        old.point != widget.point ||
        old.online != widget.online) {
      loadCapability();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> loadCapability() async {
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/points/${Uri.encodeComponent(id)}/write-capability',
      );
      if (mounted) {
        setState(() {
          capability = data;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          capability = null;
          loading = false;
          error = '无法取得下设权限，请刷新检查连接';
        });
      }
    }
  }

  Future<void> reconcile() async {
    final command = result?['command_id']?.toString();
    if (command == null || checking) return;
    checking = true;
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/commands/${Uri.encodeComponent(command)}',
      );
      if (mounted) {
        setState(() {
          result = data;
          widget.commands[id] = data;
          error = null;
        });
      }
      widget.onRefresh();
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法核对命令；不会自动重复下设');
    } finally {
      checking = false;
    }
  }

  Future<void> submit() async {
    if (!canWrite || sending || unresolved) return;
    final num? value = type == 'BOOL'
        ? (boolValue ? 1 : 0)
        : num.tryParse(input.text.trim());
    if (value == null || !value.isFinite) {
      setState(() => error = '请输入有效的有限数值');
      return;
    }
    final lower = capability?['min'], upper = capability?['max'];
    if ((lower is num && value < lower) || (upper is num && value > upper)) {
      setState(() => error = '目标值超出允许范围 ${number(lower)} ～ ${number(upper)}');
      return;
    }
    final command = 'ui-${DateTime.now().microsecondsSinceEpoch}-$id';
    setState(() {
      sending = true;
      error = null;
      pollingStarted = DateTime.now();
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/write',
        body: {
          'command_id': command,
          'point_id': id,
          'value': value,
          'version': capability!['version'],
        },
      );
      if (mounted) {
        setState(() {
          result = data;
          widget.commands[id] = data;
        });
      }
      widget.onRefresh();
    } catch (failure) {
      if (mounted) {
        final rejected =
            failure is PlatformRequestException &&
            failure.statusCode >= 400 &&
            failure.statusCode < 500;
        setState(() {
          result = {
            'command_id': command,
            'point_id': id,
            'state': rejected ? 'failed' : 'unknown',
            'value': value,
          };
          widget.commands[id] = result!;
          error = rejected ? '后端拒绝下设：${failure.message}' : '请求未得到可靠结果，请先核对命令状态';
        });
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Widget property(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(color: WorkbenchColors.muted, fontSize: 11),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: numericStyle.copyWith(fontSize: 11),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.point,
        r = widget.sample,
        c = Theme.of(context).colorScheme;
    final quality = widget.online
        ? (r['quality'] ?? 'missing').toString()
        : 'stale';
    final readonly = p['rw_mode'] == 'R' || p['writable'] != true;
    final reason = readonly
        ? '只读变量 · 无下设权限'
        : type == 'STRING'
        ? '当前后端不支持字符串下设'
        : capability?['writable'] == true
        ? '通过后端校验后发送'
        : '当前变量暂不可下设';
    return ColoredBox(
      color: c.surface,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16),
              const SizedBox(width: 8),
              const Text(
                '变量检查器',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新下设能力',
                onPressed: loadCapability,
                icon: const Icon(Icons.refresh, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Text(
            p['name'].toString(),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            '${p['station']}  /  $type  /  ${p['rw_mode'] ?? (p['writable'] == true ? 'RW' : 'R')}',
            style: const TextStyle(fontSize: 11, color: WorkbenchColors.muted),
          ),
          const SizedBox(height: 22),
          const Text(
            '当前工程值',
            style: TextStyle(color: WorkbenchColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  number(r['value']),
                  key: const Key('inspector-current-value'),
                  style: numericStyle.copyWith(
                    fontSize: 29,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 7, bottom: 4),
                child: Text(
                  (p['unit'] ?? '').toString(),
                  style: const TextStyle(color: WorkbenchColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '●  ${qualityLabel(quality)}',
            style: TextStyle(color: qualityColor(quality, c), fontSize: 11),
          ),
          const SizedBox(height: 15),
          const Divider(),
          const SizedBox(height: 10),
          property('源时间', clock(r['source_time'])),
          property('接收时间', clock(r['received_time'])),
          property('原始值', number(r['raw'])),
          property(
            '工程换算',
            '${number(p['scale_factor'])} × 原值 + ${number(p['offset'])}',
          ),
          property(
            '工程范围',
            '${number(capability?['min'] ?? p['min'])} ～ ${number(capability?['max'] ?? p['max'])} ${p['unit'] ?? ''}',
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 15),
          const Text('受控下设', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (canWrite && type == 'BOOL')
            Row(
              children: [
                Switch(
                  key: const Key('write-value'),
                  value: boolValue,
                  onChanged: unresolved || sending
                      ? null
                      : (v) => setState(() => boolValue = v),
                ),
                Text(boolValue ? '开启 / 1' : '关闭 / 0'),
              ],
            )
          else
            TextField(
              key: const Key('write-value'),
              controller: input,
              enabled: canWrite && !sending && !unresolved,
              decoration: InputDecoration(
                labelText: '目标工程值',
                suffixText: (p['unit'] ?? '').toString(),
              ),
              onSubmitted: (_) => submit(),
            ),
          const SizedBox(height: 9),
          Text(
            reason,
            style: TextStyle(
              fontSize: 11,
              color: canWrite ? c.onSurfaceVariant : WorkbenchColors.amber,
            ),
          ),
          if ((capability?['reason'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                capabilityReason(capability!['reason'].toString()),
                style: const TextStyle(
                  fontSize: 11,
                  color: WorkbenchColors.muted,
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('write-submit'),
            onPressed: canWrite && !sending && !unresolved ? submit : null,
            icon: const Icon(Icons.arrow_outward, size: 16),
            label: Text(sending ? '提交中…' : '下设工程值'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error!,
                style: TextStyle(color: c.error, fontSize: 11),
              ),
            ),
          if (result != null) ...[
            const SizedBox(height: 17),
            const Divider(),
            const SizedBox(height: 13),
            Text(
              result!['state'] == 'sent' &&
                      (result!['ack_state'] == 'unsupported' ||
                          capability?['protocol'] == 'generic')
                  ? '已发送 · 当前协议无设备确认'
                  : commandStateLabel(result!['state'].toString()),
              key: const Key('write-command-state'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: result!['state'] == 'readback_confirmed'
                    ? c.primary
                    : WorkbenchColors.amber,
              ),
            ),
            const SizedBox(height: 8),
            property('目标值', number(result!['value'])),
            property('命令时间', clock(result!['at'])),
            if (result!.containsKey('publish_state'))
              property('发送状态', phaseLabel(result!['publish_state'])),
            if (result!.containsKey('ack_state'))
              property('设备应答', phaseLabel(result!['ack_state'])),
            if (result!.containsKey('readback_state'))
              property('物理读回', phaseLabel(result!['readback_state'])),
            Text(
              p['source_type'] == 'manual' || p['source_type'] == 'simulator'
                  ? '本地／模拟点的读回不代表现场设备确认'
                  : '发送、设备应答与新鲜读回分别确认',
              style: const TextStyle(
                fontSize: 11,
                color: WorkbenchColors.muted,
              ),
            ),
            if (unresolved)
              OutlinedButton.icon(
                key: const Key('write-reconcile'),
                onPressed: reconcile,
                icon: const Icon(Icons.sync, size: 15),
                label: const Text('核对命令状态'),
              ),
          ],
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 10),
          property('变量 ID', id),
          if (p['source_type'] == 'mqtt')
            property('读取路径', '${p['source_id']} / ${p['source_path']}'),
          if (p['source_type'] == 'virtual')
            property('公式', '${p['expression']}'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: widget.onEdit,
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('编辑点位'),
          ),
        ],
      ),
    );
  }
}

String capabilityReason(String code) => switch (code) {
  'point_not_applied' => '配置尚未应用，请先应用运行配置',
  'point_read_only' || 'rw_mode_read_only' => '该变量为只读，不能下设',
  'virtual_read_only' => '计算变量没有物理下设目标',
  'string_write_unsupported' => '当前协议不支持字符串下设',
  'invalid_bool_conversion' => '布尔下设要求倍率为 1、偏移为 0',
  'write_source_missing' => '未配置下设来源',
  'protocol_write_unsupported' => '当前来源协议未实现下设',
  'kio_writer_not_configured' => 'KingIO 下设需要配置客户端与写入者',
  'write_topic_missing' => '尚未配置下设主题',
  'write_source_offline' => '下设来源未连接',
  _ => '后端暂未开放下设，请检查变量和来源配置',
};

String phaseLabel(dynamic state) => switch (state) {
  'queued' => '等待发送',
  'publishing' => '发送中',
  'sent' => '已发送',
  'pending' => '等待确认',
  'acknowledged' => '已应答',
  'confirmed' => '新鲜读回已确认',
  'not_required' => '本地点，无需设备步骤',
  'unsupported' => '当前协议未提供',
  'not_requested' => '未执行',
  'not_sent' => '未发送',
  'unconfirmed' => '未确认',
  'unknown' => '结果未知',
  'failed' => '失败',
  _ => '等待核对',
};
