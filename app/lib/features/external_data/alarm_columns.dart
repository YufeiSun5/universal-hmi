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

List<Json> validateLayout(
  dynamic value, {
  Map<String, String> fields = alarmFields,
  bool allowEmpty = false,
}) {
  if (value is! List || value.length != fields.length) {
    throw const FormatException('列配置必须包含全部固定字段');
  }
  final keys = <String>{};
  final columns = <Json>[];
  for (final c in value) {
    if (c is! Map ||
        !fields.containsKey(c['key']) ||
        !keys.add(c['key']) ||
        c['visible'] is! bool ||
        c['label'] is! String) {
      throw const FormatException('字段缺失、重复或无效');
    }
    final label = (c['label'] as String).trim();
    if (label.isEmpty ||
        utf8.encode(label).length > 256 ||
        RegExp(r'[\r\n\x00]').hasMatch(label)) {
      throw const FormatException('请填写有效列头（最多 256 字节）');
    }
    columns.add({'key': c['key'], 'visible': c['visible'], 'label': label});
  }
  if (!allowEmpty && !columns.any((c) => c['visible'] == true)) {
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
          child: ExternalColumnEditor(catalog: catalog, screen: screen),
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

class ExternalColumnEditor extends StatefulWidget {
  const ExternalColumnEditor({
    super.key,
    required this.catalog,
    required this.screen,
    this.fields = alarmFields,
    this.layoutKey = 'alarm_columns',
    this.title = '报警列配置',
    this.fileFormat = alarmFileFormat,
    this.defaults,
    this.allowEmpty = false,
  });
  final ExternalCatalog catalog;
  final Json screen;
  final Map<String, String> fields;
  final String layoutKey, title, fileFormat;
  final List<Json>? defaults;
  final bool allowEmpty;
  @override
  State<ExternalColumnEditor> createState() => _ExternalColumnEditorState();
}

class _ExternalColumnEditorState extends State<ExternalColumnEditor> {
  late var columns = [
    for (final c
        in (widget.screen[widget.layoutKey] as List? ??
            widget.defaults ??
            alarmLayout(widget.screen)))
      Map<String, dynamic>.from(c),
  ];
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
    final file = await pickProcessFile(image: false, jsonLabel: widget.title);
    if (file == null || !mounted) return;
    final data = jsonDecode(utf8.decode(file.bytes));
    if (data is! Map ||
        data['format'] != widget.fileFormat ||
        data['version'] != 1) {
      throw const FormatException('不是支持的列配置文件');
    }
    final next = validateLayout(
      data['columns'],
      fields: widget.fields,
      allowEmpty: widget.allowEmpty,
    );
    setState(() {
      columns = next;
      generation++;
      message = '已预览 ${file.name}，保存后生效';
    });
  }

  Future<void> exportFile() async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': widget.fileFormat,
          'version': 1,
          'columns': validateLayout(
            columns,
            fields: widget.fields,
            allowEmpty: widget.allowEmpty,
          ),
        }),
      ),
    );
    if (await saveFile(bytes, '${widget.title}.json') && mounted) {
      setState(() => message = '已导出当前列配置');
    }
  }

  Future<void> save() async {
    final s = await widget.catalog.api.request(
      'POST',
      '/api/v1/external/screens',
      body: {
        ...widget.screen,
        widget.layoutKey: validateLayout(
          columns,
          fields: widget.fields,
          allowEmpty: widget.allowEmpty,
        ),
      },
    );
    if (mounted) Navigator.pop(context, s);
  }

  void move(int index, int delta) => setState(() {
    final item = columns.removeAt(index);
    columns.insert(index + delta, item);
  });
  void selectAll(bool visible) => setState(() {
    for (final c in columns) {
      c['visible'] = visible;
    }
  });

  Widget columnRow(int i, Json c, bool wide) {
    final visible = c['visible'] == true;
    final field = TextFormField(
      initialValue: c['label'],
      enabled: !busy,
      decoration: InputDecoration(
        labelText: wide ? null : '显示列名',
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      onChanged: (v) => c['label'] = v,
    );
    final identity = Row(
      children: [
        Checkbox(
          value: visible,
          onChanged: busy ? null : (v) => setState(() => c['visible'] = v!),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.fields[c['key']]!,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: visible
                  ? null
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
    final arrows = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上移',
          onPressed: busy || i == 0 ? null : () => move(i, -1),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '下移',
          onPressed: busy || i + 1 == columns.length ? null : () => move(i, 1),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    );
    return Container(
      key: ValueKey('$generation-${c['key']}'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: i.isEven
            ? Theme.of(context).colorScheme.surface
            : Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: wide
          ? Row(
              children: [
                SizedBox(width: 162, child: identity),
                const SizedBox(width: 8),
                Expanded(child: field),
                const SizedBox(width: 12),
                arrows,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: identity),
                    arrows,
                  ],
                ),
                const SizedBox(height: 8),
                field,
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = columns.where((c) => c['visible'] == true).length;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 560;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.view_column_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: theme.textTheme.titleLarge,
                            ),
                            Text(
                              "${widget.screen['name']}  ·  已显示 $count / ${columns.length} 列",
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
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
                                onPressed: busy ? null : () => selectAll(true),
                                child: const Text('全选'),
                              ),
                              TextButton(
                                onPressed: busy ? null : () => selectAll(false),
                                child: const Text('清空'),
                              ),
                            ],
                          ),
                        ),
                        if (wide)
                          Container(
                            color: theme.colorScheme.secondaryContainer,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: const Row(
                              children: [
                                SizedBox(width: 162, child: Text('显示 / 原字段')),
                                Expanded(child: Text('运行端列名')),
                                SizedBox(
                                  width: 96,
                                  child: Text(
                                    '调整顺序',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final (i, c) in columns.indexed)
                          columnRow(i, c, wide),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(message!),
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: busy ? null : () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: busy || (count == 0 && !widget.allowEmpty)
                            ? null
                            : () => run(save),
                        child: const Text('保存配置'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
