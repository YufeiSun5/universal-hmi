import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../platform/process_files.dart';
import 'catalog.dart';
import '../../shared/form_control_theme.dart';

const alarmFields = {
  'event_time': '事件时间',
  'alarm_time': '报警发生时间',
  'tag': '变量名称',
  'event_type': '事件类型',
  'alarm_value': '报警值',
  'resume_value': '恢复值',
  'operator': '操作人',
  'description': '报警描述',
  'comment': '变量说明',
  'group': '分组',
  'alarm_type': '报警类型',
  'priority': '优先级',
  'limit_value': '限值',
};

List<Json> alarmLayout(Json screen) => screen['alarm_columns'] == null
    ? [
        for (final f in alarmFields.entries)
          {'key': f.key, 'label': f.value, 'visible': true},
      ]
    : [for (final c in screen['alarm_columns']) Map<String, dynamic>.from(c)];

const alarmFileFormat = 'universal-hmi-alarm-columns';

List<Json> validateLayout(dynamic value) {
  if (value is! List || value.length != alarmFields.length) {
    throw const FormatException('列配置必须包含全部报警字段');
  }
  final keys = <String>{};
  final columns = <Json>[];
  for (final c in value) {
    if (c is! Map ||
        !alarmFields.containsKey(c['key']) ||
        !keys.add(c['key']) ||
        c['visible'] is! bool ||
        c['label'] is! String) {
      throw const FormatException('报警字段缺失、重复或无效');
    }
    final label = (c['label'] as String).trim();
    if (label.isEmpty ||
        utf8.encode(label).length > 256 ||
        RegExp(r'[\r\n\x00]').hasMatch(label)) {
      throw const FormatException('请填写有效列头（最多 256 字节）');
    }
    columns.add({'key': c['key'], 'visible': c['visible'], 'label': label});
  }
  if (!columns.any((c) => c['visible'] == true)) {
    throw const FormatException('至少显示一列');
  }
  return columns;
}

List<Json> decodeAlarmLayout(Uint8List bytes) {
  final data = jsonDecode(utf8.decode(bytes));
  if (data is! Map ||
      data['format'] != alarmFileFormat ||
      data['version'] != 1) {
    throw const FormatException('不是支持的报警列配置文件');
  }
  return validateLayout(data['columns']);
}

Uint8List encodeAlarmLayout(List<Json> columns) {
  final data = {
    'format': alarmFileFormat,
    'version': 1,
    'columns': validateLayout(columns),
  };
  return Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
  );
}

class AlarmColumnAction extends StatelessWidget {
  const AlarmColumnAction({
    super.key,
    required this.catalog,
    required this.screen,
    this.onSaved,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final ValueChanged<Json>? onSaved;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () async {
      final saved = await showDialog<Json>(
        context: context,
        builder: (_) => FormControlTheme(
          child: AlarmColumnEditor(catalog: catalog, screen: screen),
        ),
      );
      if (saved != null) {
        await catalog.load();
        onSaved?.call(saved);
      }
    },
    icon: const Icon(Icons.view_column_outlined),
    label: const Text('报警列配置'),
  );
}

class AlarmColumnEditor extends StatefulWidget {
  const AlarmColumnEditor({
    super.key,
    required this.catalog,
    required this.screen,
  });
  final ExternalCatalog catalog;
  final Json screen;
  @override
  State<AlarmColumnEditor> createState() => _AlarmColumnEditorState();
}

class _AlarmColumnEditorState extends State<AlarmColumnEditor> {
  late var columns = alarmLayout(widget.screen);
  var generation = 0;
  bool busy = false;
  String? message;
  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> importFile() async {
    final file = await pickProcessFile(image: false, jsonLabel: '报警列配置');
    if (file == null || !mounted) return;
    final next = decodeAlarmLayout(file.bytes);
    setState(() {
      columns = next;
      generation++;
      message = '已预览 ${file.name}，保存后生效';
    });
  }

  Future<void> exportFile() async {
    if (await saveFile(encodeAlarmLayout(columns), '报警列配置.json') && mounted) {
      setState(() => message = '已导出当前列配置');
    }
  }

  Future<void> save() async {
    final s = await widget.catalog.api.request(
      'POST',
      '/api/v1/external/screens',
      body: {...widget.screen, 'alarm_columns': validateLayout(columns)},
    );
    if (mounted) Navigator.pop(context, s);
  }

  void move(int index, int delta) => setState(() {
    final item = columns.removeAt(index);
    columns.insert(index + delta, item);
  });
  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    title: const Text('报警列配置'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => run(importFile),
                  child: const Text('导入配置'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => run(exportFile),
                  child: const Text('导出配置'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          for (final c in columns) {
                            c['visible'] = true;
                          }
                        }),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          for (final c in columns) {
                            c['visible'] = false;
                          }
                        }),
                  child: const Text('清空'),
                ),
              ],
            ),
            for (final (i, c) in columns.indexed)
              Column(
                key: ValueKey('$generation-${c['key']}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  TextFormField(
                    initialValue: c['label'],
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: '${alarmFields[c['key']]} · 列头',
                    ),
                    onChanged: (v) => c['label'] = v,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('显示'),
                        selected: c['visible'],
                        onSelected: busy
                            ? null
                            : (v) => setState(() => c['visible'] = v),
                      ),
                      IconButton(
                        tooltip: '上移',
                        onPressed: busy || i == 0 ? null : () => move(i, -1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: '下移',
                        onPressed: busy || i + 1 == columns.length
                            ? null
                            : () => move(i, 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
    actionsOverflowButtonSpacing: 8,
    actions: [
      if (message != null) Text(message!),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy ? null : () => run(save),
        child: const Text('保存配置'),
      ),
    ],
  );
}
