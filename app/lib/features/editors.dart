import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/table.dart';

class EditorFrame extends StatefulWidget {
  const EditorFrame({
    super.key,
    required this.title,
    required this.content,
    required this.save,
    this.label = '保存',
    this.width = 620,
    this.controllers = const [],
  });
  final String title, label;
  final Widget content;
  final Future<Object?> Function() save;
  final double width;
  final List<TextEditingController> controllers;
  @override
  State<EditorFrame> createState() => _EditorFrameState();
}

class _EditorFrameState extends State<EditorFrame> {
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbsorbPointer(absorbing: busy, child: widget.content),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    final result = await widget.save();
                    if (!context.mounted) return;
                    Navigator.pop(context, result ?? true);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        busy = false;
                        error = e.toString();
                      });
                    }
                  }
                },
          child: Text(busy ? '处理中…' : widget.label),
        ),
      ],
    ),
  );
}

String? requiredText(String? value) =>
    value == null || value.trim().isEmpty ? '请填写此项' : null;
String? finiteNumber(String? value) {
  final n = double.tryParse(value ?? '');
  return n == null || !n.isFinite ? '请输入有限数字' : null;
}

Widget field(
  TextEditingController c,
  String label, {
  String? Function(String?)? validate,
  Key? key,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: TextFormField(
    key: key,
    controller: c,
    decoration: InputDecoration(labelText: label),
    validator: validate,
  ),
);
Widget section(String label) => Padding(
  padding: const EdgeInsets.only(top: 10, bottom: 12),
  child: Align(
    alignment: Alignment.centerLeft,
    child: Text(
      label,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  ),
);
Widget select(
  String label,
  String value,
  List<String> options,
  ValueChanged<String> change, {
  Map<String, String>? labels,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: DropdownButtonFormField<String>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    isExpanded: true,
    items: options
        .map(
          (o) => DropdownMenuItem(
            value: o,
            child: Text(labels?[o] ?? o, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) change(v);
    },
  ),
);

Future<Object?> pointEditor(
  BuildContext context,
  PlatformApi api,
  List<Json> points, {
  Json? existing,
  String? station,
}) async {
  final p = existing ?? <String, dynamic>{};
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  for (final key in [
    'station',
    'name',
    'unit',
    'source_id',
    'source_path',
    'topic',
    'write_topic',
    'write_source_id',
    'write_path',
    'expression',
    'min',
    'max',
    'scale_factor',
    'offset',
    'stale_ms',
  ]) {
    final defaultValue = switch (key) {
      'station' => station ?? 'IO-01',
      'scale_factor' => '1',
      'offset' => '0',
      'stale_ms' => '5000',
      _ => '',
    };
    fields[key] = TextEditingController(
      text: (p[key] ?? defaultValue).toString(),
    );
  }
  var source = (p['source_type'] ?? 'manual').toString(),
      type = (p['data_type'] ?? 'FLOAT').toString(),
      writable = p['writable'] == true,
      rwMode = (p['rw_mode'] ?? (p['writable'] == true ? 'RW' : 'R'))
          .toString();
  var inputs = (p['inputs'] as List? ?? []).map((v) => v.toString()).toList();
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => EditorFrame(
        title: existing == null ? '添加点位' : '编辑点位',
        controllers: fields.values.toList(),
        label: '保存配置',
        content: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              section('身份与归属'),
              Row(
                children: [
                  Expanded(
                    child: field(
                      fields['station']!,
                      '站点',
                      validate: requiredText,
                      key: const Key('point-station'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: field(
                      fields['name']!,
                      '点位名称',
                      validate: requiredText,
                      key: const Key('point-name'),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: select('数据类型', type, [
                      'FLOAT',
                      'INT',
                      'BOOL',
                      'STRING',
                    ], (v) => update(() => type = v)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: select(
                      '来源类型',
                      source,
                      ['manual', 'virtual', 'mqtt', 'simulator'],
                      (v) => update(() => source = v),
                      labels: {
                        'manual': '手工输入',
                        'virtual': '计算点',
                        'mqtt': 'MQTT',
                        'simulator': '模拟点',
                      },
                    ),
                  ),
                ],
              ),
              field(fields['unit']!, '单位'),
              if (source == 'mqtt') ...[
                section('采集映射'),
                field(fields['source_id']!, '来源 ID', validate: requiredText),
                field(fields['topic']!, '消息主题（空白匹配来源全部主题）'),
                field(
                  fields['source_path']!,
                  '源点位路径／ID',
                  validate: requiredText,
                ),
              ],
              if (source == 'virtual') ...[
                section('计算公式'),
                field(
                  fields['expression']!,
                  '公式，例如 (v[0] + v[1]) / 2',
                  validate: requiredText,
                ),
                const Text(
                  '按选中顺序对应 v[0]、v[1]；无效输入传播坏质量。',
                  style: TextStyle(fontSize: 11),
                ),
                Wrap(
                  spacing: 6,
                  children: points.where((r) => r['id'] != p['id']).map((r) {
                    final id = r['id'].toString();
                    return FilterChip(
                      label: Text(
                        '${r['station'] ?? ''} / ${r['name']}${inputs.contains(id) ? ' [${inputs.indexOf(id)}]' : ''}',
                      ),
                      selected: inputs.contains(id),
                      onSelected: (v) => update(() {
                        if (v) {
                          inputs.add(id);
                        } else {
                          inputs.remove(id);
                        }
                      }),
                    );
                  }).toList(),
                ),
              ],
              section('换算与数据质量'),
              Row(
                children: [
                  Expanded(
                    child: field(
                      fields['scale_factor']!,
                      '缩放倍率',
                      validate: (v) {
                        final err = finiteNumber(v);
                        if (err != null) return err;
                        return double.parse(v!) == 0 ? '倍率不能为零' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: field(
                      fields['offset']!,
                      '偏移',
                      validate: finiteNumber,
                    ),
                  ),
                ],
              ),
              field(
                fields['stale_ms']!,
                '陈旧阈值（毫秒）',
                validate: (v) => int.tryParse(v ?? '') == null ? '请输入整数' : null,
              ),
              if (source != 'virtual')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许受控下设'),
                  value: writable,
                  onChanged: (v) => update(() => writable = v),
                ),
              if (source != 'virtual')
                select(
                  '读写模式',
                  rwMode,
                  ['R', 'W', 'RW'],
                  (v) => update(() => rwMode = v),
                  labels: {'R': 'R · 只读', 'W': 'W · 只写', 'RW': 'RW · 读写'},
                ),
              if (writable && source != 'virtual') ...[
                Row(
                  children: [
                    Expanded(child: field(fields['min']!, '工程值下限（可选）')),
                    const SizedBox(width: 12),
                    Expanded(child: field(fields['max']!, '工程值上限（可选）')),
                  ],
                ),
                if (source == 'mqtt') ...[
                  field(fields['write_source_id']!, '下设来源 ID（空白沿用采集来源）'),
                  field(fields['write_path']!, '下设路径（空白沿用源路径）'),
                  field(fields['write_topic']!, '下设主题（KingIO 可由客户端 ID 自动推导）'),
                ],
              ],
              const Text('保存后点击「应用配置」使新定义生效。', style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
        save: () async {
          if (!form.currentState!.validate()) throw Exception('请修正配置字段');
          final input = <String, dynamic>{
            for (final k in [
              'station',
              'name',
              'unit',
              'source_id',
              'source_path',
              'topic',
              'write_topic',
              'write_source_id',
              'write_path',
              'expression',
            ])
              k: fields[k]!.text.trim(),
            'data_type': type,
            'source_type': source,
            'scale_factor': double.parse(fields['scale_factor']!.text),
            'offset': double.parse(fields['offset']!.text),
            'stale_ms': int.parse(fields['stale_ms']!.text),
            'writable': source != 'virtual' && writable,
            'rw_mode': source == 'virtual' ? 'R' : rwMode,
            'inputs': inputs,
            'min': fields['min']!.text.isEmpty
                ? null
                : double.parse(fields['min']!.text),
            'max': fields['max']!.text.isEmpty
                ? null
                : double.parse(fields['max']!.text),
          };
          final path = existing == null
              ? '/api/v1/points'
              : '/api/v1/points/${p['id']}';
          return api.request(
            existing == null ? 'POST' : 'PUT',
            path,
            body: input,
          );
        },
      ),
    ),
  );
  return result;
}

Future<Object?> sourceEditor(
  BuildContext context,
  PlatformApi api,
  List<Json> sources, {
  Json? existing,
}) async {
  final form = GlobalKey<FormState>(), p = existing ?? <String, dynamic>{};
  final id = TextEditingController(
    text: (p['id'] ?? 'source-${DateTime.now().millisecondsSinceEpoch}')
        .toString(),
  );
  final name = TextEditingController(text: (p['name'] ?? '采集服务').toString()),
      broker = TextEditingController(
        text: (p['broker'] ?? 'tcp://127.0.0.1:1883').toString(),
      ),
      topic = TextEditingController(
        text: (p['topic'] ?? 'stations/#').toString(),
      );
  final clientID = TextEditingController(
        text: (p['client_id'] ?? '').toString(),
      ),
      writer = TextEditingController(text: (p['writer'] ?? '').toString()),
      ackTimeout = TextEditingController(
        text: (p['ack_timeout_ms'] ?? 3000).toString(),
      );
  var protocol = (p['protocol'] ?? 'generic').toString();
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => EditorFrame(
        title: 'MQTT 来源',
        controllers: [id, name, broker, topic, clientID, writer, ackTimeout],
        content: Form(
          key: form,
          child: Column(
            children: [
              field(id, '稳定来源 ID', validate: requiredText),
              field(name, '显示名称', validate: requiredText),
              field(broker, 'Broker 地址', validate: requiredText),
              field(topic, '订阅主题', validate: requiredText),
              select(
                '消息格式',
                protocol,
                ['generic', 'kep', 'kingio'],
                (v) => update(() => protocol = v),
                labels: {
                  'generic': '通用 points 格式',
                  'kep': 'Kepware values 格式',
                  'kingio': 'KingIO Objs 格式',
                },
              ),
              if (protocol == 'kingio') ...[
                field(clientID, 'KingIO 客户端 ID'),
                field(writer, 'KingIO 写入者 Writer'),
                field(
                  ackTimeout,
                  '应答超时（毫秒）',
                  validate: (v) =>
                      int.tryParse(v ?? '') == null ? '请输入整数' : null,
                ),
              ],
              const Text(
                '保存连接配置后，使用「连接」开始采集。编辑现有来源前先断开。',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        save: () async {
          if (!form.currentState!.validate()) throw Exception('请填写完整来源');
          final row = <String, dynamic>{
            'id': id.text.trim(),
            'name': name.text.trim(),
            'broker': broker.text.trim(),
            'topic': topic.text.trim(),
            'protocol': protocol,
            'client_id': clientID.text.trim(),
            'writer': writer.text.trim(),
            'ack_timeout_ms': int.tryParse(ackTimeout.text) ?? 3000,
          };
          final next = [
            ...sources.where((s) => s['id'] != existing?['id']),
            row,
          ];
          await api.request('PUT', '/api/v1/sources', body: {'items': next});
          return true;
        },
      ),
    ),
  );
  return result;
}

Future<Object?> ruleEditor(
  BuildContext context,
  PlatformApi api,
  List<Json> points,
  List<Json> rules, {
  Json? existing,
  String station = '',
}) async {
  if (points.isEmpty) return null;
  final p = existing ?? <String, dynamic>{}, form = GlobalKey<FormState>();
  final name = TextEditingController(text: (p['name'] ?? '条件事件').toString()),
      hold = TextEditingController(text: (p['hold_ms'] ?? 500).toString()),
      cooldown = TextEditingController(
        text: (p['cooldown_ms'] ?? 5000).toString(),
      );
  final id = (p['id'] ?? 'rule-${DateTime.now().microsecondsSinceEpoch}')
      .toString();
  var logic = (p['logic'] ?? 'and').toString(),
      trigger = (p['trigger'] ?? 'rising').toString(),
      enabled = p['enabled'] == true;
  final conditions = objects(p['conditions']);
  if (conditions.isEmpty) {
    conditions.add({'point_id': points.first['id'], 'op': '>', 'value': 40});
  }
  final actions = objects(p['actions']);
  if (actions.isEmpty) {
    actions.add({'type': 'snapshot', 'point_id': '', 'value': 0});
  }
  final labels = {
    for (final r in points)
      r['id'].toString(): '${r['station']} / ${r['name']}',
  };
  final ids = labels.keys.toList();
  Json definition() => {
    'id': id,
    'station': p['station'] ?? station,
    'name': name.text.trim(),
    'enabled': enabled,
    'logic': logic,
    'trigger': trigger,
    'hold_ms': int.parse(hold.text),
    'cooldown_ms': int.parse(cooldown.text),
    'conditions': conditions,
    'actions': actions,
  };
  String? preview;
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => EditorFrame(
        title: '条件事件',
        controllers: [name, hold, cooldown],
        width: 760,
        content: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field(name, '规则名称', validate: requiredText),
              Row(
                children: [
                  Expanded(
                    child: select(
                      '条件组合',
                      logic,
                      ['and', 'or'],
                      (v) => update(() => logic = v),
                      labels: {'and': '同时满足 AND', 'or': '任一满足 OR'},
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: select(
                      '触发方式',
                      trigger,
                      ['rising', 'periodic', 'recovery'],
                      (v) => update(() => trigger = v),
                      labels: {
                        'rising': '首次成立',
                        'periodic': '成立时按冷却周期',
                        'recovery': '条件恢复',
                      },
                    ),
                  ),
                ],
              ),
              section('条件'),
              ...List.generate(conditions.length, (i) {
                final r = conditions[i];
                return Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: select(
                        '点位',
                        ids.contains(r['point_id'])
                            ? r['point_id'].toString()
                            : ids.first,
                        ids,
                        (v) => update(() => r['point_id'] = v),
                        labels: labels,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: select('比较', r['op'].toString(), [
                        '>',
                        '>=',
                        '<',
                        '<=',
                        '==',
                        '!=',
                      ], (v) => update(() => r['op'] = v)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TextFormField(
                          initialValue: r['value'].toString(),
                          decoration: const InputDecoration(labelText: '阈值'),
                          validator: finiteNumber,
                          onChanged: (v) {
                            final n = double.tryParse(v);
                            if (n != null) r['value'] = n;
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: conditions.length == 1
                          ? null
                          : () => update(() => conditions.removeAt(i)),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ],
                );
              }),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => update(
                    () => conditions.add({
                      'point_id': ids.first,
                      'op': '>',
                      'value': 0,
                    }),
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加条件'),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: field(
                      hold,
                      '持续满足（毫秒）',
                      validate: (v) =>
                          int.tryParse(v ?? '') == null ? '请输入整数' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: field(
                      cooldown,
                      '冷却时间（毫秒）',
                      validate: (v) =>
                          int.tryParse(v ?? '') == null ? '请输入整数' : null,
                    ),
                  ),
                ],
              ),
              section('动作序列'),
              ...List.generate(actions.length, (i) {
                final a = actions[i];
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: select(
                            '动作',
                            a['type'].toString(),
                            [
                              'snapshot',
                              'storage_start',
                              'storage_stop',
                              'write',
                            ],
                            (v) => update(() {
                              a['type'] = v;
                              if (v == 'write' &&
                                  !ids.contains(a['point_id'])) {
                                a['point_id'] = ids.first;
                              }
                            }),
                            labels: {
                              'snapshot': '存储当前快照',
                              'storage_start': '开始独立存储',
                              'storage_stop': '停止独立存储',
                              'write': '受控下设',
                            },
                          ),
                        ),
                        IconButton(
                          onPressed: actions.length == 1
                              ? null
                              : () => update(() => actions.removeAt(i)),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                    if (a['type'] == 'write')
                      Row(
                        children: [
                          Expanded(
                            child: select(
                              '写入点位',
                              ids.contains(a['point_id'])
                                  ? a['point_id'].toString()
                                  : ids.first,
                              ids,
                              (v) => update(() => a['point_id'] = v),
                              labels: labels,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              initialValue: a['value'].toString(),
                              decoration: const InputDecoration(
                                labelText: '工程值',
                              ),
                              validator: finiteNumber,
                              onChanged: (v) {
                                final n = double.tryParse(v);
                                if (n != null) a['value'] = n;
                              },
                            ),
                          ),
                        ],
                      ),
                  ],
                );
              }),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => update(
                    () => actions.add({
                      'type': 'snapshot',
                      'point_id': '',
                      'value': 0,
                    }),
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加动作'),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存后启用规则'),
                subtitle: const Text('预览只判断条件，不执行任何动作'),
                value: enabled,
                onChanged: (v) => update(() => enabled = v),
              ),
              OutlinedButton(
                onPressed: () async {
                  try {
                    if (!form.currentState!.validate()) return;
                    final result = await api.request(
                      'POST',
                      '/api/v1/rules/preview',
                      body: definition(),
                    );
                    if (!context.mounted) return;
                    update(
                      () => preview =
                          (result['error'] ?? '').toString().isNotEmpty
                          ? '规则无效：${result['error']}'
                          : result['known'] == true
                          ? (result['matches'] == true ? '当前条件成立' : '当前条件未成立')
                          : '输入缺失、坏质量或陈旧，条件未知',
                    );
                  } catch (e) {
                    if (context.mounted) update(() => preview = e.toString());
                  }
                },
                child: const Text('预览条件'),
              ),
              if (preview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(preview!),
                ),
            ],
          ),
        ),
        save: () async {
          if (!form.currentState!.validate()) throw Exception('请修正规则');
          final row = definition();
          await api.request(
            'PUT',
            '/api/v1/rules',
            body: {
              'items': [...rules.where((r) => r['id'] != id), row],
            },
          );
          return true;
        },
      ),
    ),
  );
  return result;
}

Future<Object?> importEditor(
  BuildContext context,
  PlatformApi api,
  Json upload,
) async {
  final sheets = objects(upload['sheets']);
  if (sheets.isEmpty) throw Exception('文件没有工作表');
  var sheet = sheets.first['name'].toString(),
      timeColumn = 0,
      valueColumn = 1,
      header = true;
  final station = TextEditingController(text: '导入数据'),
      name = TextEditingController(text: '分析数据'),
      unit = TextEditingController();
  Json? preview;
  String? error;
  bool previewing = false;
  Json mapping() => {
    'session_id': upload['session_id'],
    'sheet': sheet,
    'time_column': timeColumn,
    'value_column': valueColumn,
    'header': header,
    'station': station.text.trim(),
    'name': name.text.trim(),
    'unit': unit.text.trim(),
  };
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final current = sheets.firstWhere((s) => s['name'] == sheet),
            rows = (current['preview'] as List)
                .map((r) => (r as List).map((v) => v.toString()).toList())
                .toList();
        final columns = List.generate(
          rows.isEmpty ? 2 : math.max(2, rows.first.length),
          (i) => i.toString(),
        );
        final labels = {
          for (final i in columns)
            i: '列 ${int.parse(i) + 1}${header && rows.isNotEmpty && int.parse(i) < rows.first.length ? ' · ${rows.first[int.parse(i)]}' : ''}',
        };
        return EditorFrame(
          title: '工作表与列映射',
          controllers: [station, name, unit],
          label: '导入历史数据',
          width: 800,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              select(
                '工作表',
                sheet,
                sheets.map((s) => s['name'].toString()).toList(),
                (v) => update(() {
                  sheet = v;
                  preview = null;
                  timeColumn = 0;
                  valueColumn = 1;
                }),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('第一行为表头'),
                value: header,
                onChanged: (v) => update(() {
                  header = v ?? true;
                  preview = null;
                }),
              ),
              Row(
                children: [
                  Expanded(
                    child: select(
                      '时间列',
                      timeColumn.toString(),
                      columns,
                      (v) => update(() {
                        timeColumn = int.parse(v);
                        preview = null;
                      }),
                      labels: labels,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: select(
                      '数值列',
                      valueColumn.toString(),
                      columns,
                      (v) => update(() {
                        valueColumn = int.parse(v);
                        preview = null;
                      }),
                      labels: labels,
                    ),
                  ),
                ],
              ),
              const Text(
                '无时区的时间按 UTC 解释；支持 ISO、Unix 时间戳和 Excel 日期。',
                style: TextStyle(fontSize: 11),
              ),
              SizedBox(
                height: 180,
                child: DenseTable(
                  headers: columns.map((v) => labels[v]!).toList(),
                  rows: rows,
                ),
              ),
              Row(
                children: [
                  Expanded(child: field(station, '归属站点')),
                  const SizedBox(width: 12),
                  Expanded(child: field(name, '数据名称')),
                  const SizedBox(width: 12),
                  Expanded(child: field(unit, '单位')),
                ],
              ),
              OutlinedButton(
                onPressed: previewing
                    ? null
                    : () async {
                        update(() => previewing = true);
                        try {
                          final p = await api.request(
                            'POST',
                            '/api/v1/import/preview',
                            body: mapping(),
                          );
                          if (!context.mounted) return;
                          update(() {
                            preview = p;
                            error = null;
                          });
                        } catch (e) {
                          if (context.mounted) {
                            update(() => error = e.toString());
                          }
                        } finally {
                          if (context.mounted) update(() => previewing = false);
                        }
                      },
                child: Text(previewing ? '预览中…' : '验证映射并预览'),
              ),
              if (preview != null) Text('有效行数：${preview!['count']}'),
              if (preview != null && objects(preview!['rows']).isNotEmpty)
                SizedBox(
                  height: 150,
                  child: DenseTable(
                    headers: const ['源行', 'UTC 时间', '数值'],
                    rows: objects(preview!['rows'])
                        .map(
                          (r) => [
                            r['row'].toString(),
                            r['time'].toString(),
                            number(r['value']),
                          ],
                        )
                        .toList(),
                  ),
                ),
              if (preview != null)
                ...((preview!['errors'] as List?) ?? []).map(
                  (v) => Text(
                    v.toString(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          save: () async {
            if (preview == null) throw Exception('请先验证列映射');
            if ((preview!['errors'] as List).isNotEmpty) {
              throw Exception('请修正源数据中的错误');
            }
            return api.request(
              'POST',
              '/api/v1/import/commit',
              body: mapping(),
            );
          },
        );
      },
    ),
  );
  return result;
}

Future<String?> inputValue(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => EditorFrame(
      title: title,
      controllers: [controller],
      content: TextField(controller: controller, autofocus: true),
      save: () async => controller.text,
      label: '确定',
    ),
  );
}

String pretty(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
