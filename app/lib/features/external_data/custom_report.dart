import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/date_time_field.dart';
import '../../shared/query_control_theme.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/table.dart';
import '../../shared/table_csv.dart';
import '../../shared/report_style.dart';

class CustomReportQuery extends StatefulWidget {
  const CustomReportQuery({
    super.key,
    required this.api,
    required this.screen,
    this.actions = const [],
  });
  final PlatformApi api;
  final Json screen;
  final List<Widget> actions;
  @override
  State<CustomReportQuery> createState() => _CustomReportQueryState();
}

class _CustomReportQueryState extends State<CustomReportQuery> {
  late final parameters = objects(widget.screen['procedure']?['parameters']);
  late final inputs = {
    for (final p in parameters)
      '${p['name']}': TextEditingController(text: '${p['default'] ?? ''}'),
  };
  List<String> columns = [];
  List<Json> rows = [];
  bool busy = false;
  String? error;
  int generation = 0;
  @override
  void dispose() {
    generation++;
    for (final c in inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  void changed() {
    generation++;
    setState(() {
      busy = false;
      rows = [];
      error = null;
    });
  }

  Future<void> query() async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      rows = [];
      error = null;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/external/screens/${widget.screen['id']}/query',
        body: {
          'parameters': {
            for (final p in parameters)
              if (inputs[p['name']]!.text.isNotEmpty || p['required'] == true)
                '${p['name']}': inputs[p['name']]!.text,
          },
        },
      );
      if (!mounted || ticket != generation) return;
      setState(() {
        columns = [for (final c in data['report_columns'] ?? []) '$c'];
        rows = objects(data['report_rows']);
      });
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> export() async {
    final csv = TableCsv(styles: ReportStyleScope.of(context)?.styles)
      ..add(columns);
    for (final r in rows) {
      csv.add([for (final c in columns) r[c]?.toString() ?? '—']);
    }
    try {
      final saved = await csv.save('${widget.screen['name']}.csv');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(saved ? '导出已完成' : '已取消导出')));
      }
    } catch (e) {
      if (mounted) setState(() => error = '导出失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QueryHeading(
          title: '${widget.screen['name']}',
          actions: widget.actions,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: QueryToolbar(
            fields: [
              for (final p in parameters)
                SizedBox(
                  width: 210,
                  child: p['type'] == 'date' || p['type'] == 'datetime'
                      ? DateTimeField(
                          controller: inputs[p['name']]!,
                          label:
                              '${p['label']}${p['required'] == true ? ' *' : ''}',
                          includeTime: p['type'] == 'datetime',
                          onChanged: (_) => changed(),
                        )
                      : TextField(
                          controller: inputs[p['name']],
                          decoration: InputDecoration(
                            labelText:
                                '${p['label']}${p['required'] == true ? ' *' : ''}',
                            hintText: p['type'] == 'date'
                                ? 'YYYY-MM-DD'
                                : p['type'] == 'datetime'
                                ? 'YYYY-MM-DD HH:mm:ss'
                                : p['type'] == 'boolean'
                                ? 'true / false'
                                : null,
                          ),
                          onChanged: (_) => changed(),
                          onSubmitted: (_) => query(),
                        ),
                ),
            ],
            actions: [
              FilledButton.icon(
                onPressed: busy ? null : query,
                icon: const Icon(Icons.search),
                label: Text(busy ? '查询中…' : '查询'),
              ),
              OutlinedButton.icon(
                onPressed: rows.isEmpty ? null : export,
                icon: const Icon(Icons.download_outlined),
                label: const Text('导出'),
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: columns.isEmpty
              ? const Center(child: Text('填写查询条件后生成报表'))
              : DenseTable(
                  reportStyle: true,
                  headers: columns,
                  rowCount: rows.length,
                  rowBuilder: (i) => [
                    for (final c in columns) rows[i][c]?.toString() ?? '—',
                  ],
                ),
        ),
      ],
    ),
  );
}

/// Stored definition editor: identifiers and typed parameters only, never SQL text.
class ProcedureEditor extends StatefulWidget {
  const ProcedureEditor({
    super.key,
    required this.api,
    required this.sourceID,
    this.value,
    required this.onChanged,
  });
  final PlatformApi api;
  final String sourceID;
  final Json? value;
  final ValueChanged<Json> onChanged;
  @override
  State<ProcedureEditor> createState() => _ProcedureEditorState();
}

class _ProcedureEditorState extends State<ProcedureEditor> {
  late final schema = TextEditingController(
    text: '${widget.value?['schema'] ?? 'dbo'}',
  );
  late final name = TextEditingController(
    text: '${widget.value?['name'] ?? ''}',
  );
  late List<Json> parameters = objects(
    widget.value?['parameters'],
  ).map((p) => Map<String, dynamic>.of(p)).toList();
  bool busy = false;
  String? error;
  List<Json> metadata = [];
  @override
  void dispose() {
    schema.dispose();
    name.dispose();
    super.dispose();
  }

  void change() => widget.onChanged({
    'schema': schema.text.trim(),
    'name': name.text.trim(),
    'parameters': parameters,
  });
  String type(String sql) => switch (sql) {
    'date' => 'date',
    'datetime' ||
    'datetime2' ||
    'smalldatetime' ||
    'datetimeoffset' => 'datetime',
    'int' || 'bigint' || 'smallint' || 'tinyint' => 'integer',
    'decimal' ||
    'numeric' ||
    'money' ||
    'smallmoney' ||
    'float' ||
    'real' => 'decimal',
    'bit' => 'boolean',
    _ => 'text',
  };
  Future<void> discover() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/external/sources/${widget.sourceID}/procedures',
      );
      if (mounted) setState(() => metadata = objects(data['items']));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 16),
      const Text('报表存储过程', style: TextStyle(fontWeight: FontWeight.w600)),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '选择用于读取报表的存储过程。使用只授予所需查询权限的数据库账号；过程返回一张结果表，每列须有唯一名称。',
          style: TextStyle(fontSize: 12),
        ),
      ),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          SizedBox(
            width: 105,
            child: TextField(
              controller: schema,
              decoration: const InputDecoration(labelText: '架构'),
              onChanged: (_) => change(),
            ),
          ),
          SizedBox(
            width: 270,
            child: TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '存储过程名称'),
              onChanged: (_) => change(),
            ),
          ),
          OutlinedButton(
            onPressed: busy ? null : discover,
            child: Text(busy ? '读取中…' : '读取过程目录'),
          ),
        ],
      ),
      if (metadata.isNotEmpty)
        DropdownButtonFormField<String>(
          isExpanded: true,
          decoration: const InputDecoration(labelText: '从目录选择（会替换参数配置）'),
          items: [
            for (final id
                in metadata.map((m) => '${m['schema']}.${m['name']}').toSet())
              DropdownMenuItem(
                value: id,
                child: Text(id, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            final selected = metadata
                .where((m) => '${m['schema']}.${m['name']}' == id)
                .toList();
            setState(() {
              schema.text = '${selected.first['schema']}';
              name.text = '${selected.first['name']}';
              parameters = [
                for (final p in selected)
                  if (p['parameter'] != '' && p['output'] != 'true')
                    {
                      'name': p['parameter'],
                      'label': p['parameter'],
                      'type': type('${p['sql_type']}'),
                      'required': false,
                    },
              ];
            });
            change();
          },
        ),
      for (var i = 0; i < parameters.length; i++)
        Padding(
          key: ObjectKey(parameters[i]),
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 125,
                child: TextFormField(
                  initialValue: '${parameters[i]['name']}',
                  decoration: const InputDecoration(labelText: '参数名（无@）'),
                  onChanged: (v) {
                    parameters[i]['name'] = v;
                    change();
                  },
                ),
              ),
              SizedBox(
                width: 125,
                child: TextFormField(
                  initialValue: '${parameters[i]['label']}',
                  decoration: const InputDecoration(labelText: '查询条件名称'),
                  onChanged: (v) {
                    parameters[i]['label'] = v;
                    change();
                  },
                ),
              ),
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<String>(
                  initialValue: '${parameters[i]['type']}',
                  decoration: const InputDecoration(labelText: '类型'),
                  items: [
                    for (final t in {
                      'text': '文本',
                      'date': '日期',
                      'datetime': '日期时间',
                      'integer': '整数',
                      'decimal': '小数',
                      'boolean': '布尔',
                    }.entries)
                      DropdownMenuItem(value: t.key, child: Text(t.value)),
                  ],
                  onChanged: (v) {
                    parameters[i]['type'] = v;
                    change();
                  },
                ),
              ),
              SizedBox(
                width: 140,
                child: TextFormField(
                  initialValue: '${parameters[i]['default'] ?? ''}',
                  decoration: const InputDecoration(labelText: '默认值（可空）'),
                  onChanged: (v) {
                    parameters[i]['default'] = v;
                    change();
                  },
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: parameters[i]['required'] == true,
                    onChanged: (v) {
                      setState(() => parameters[i]['required'] = v);
                      change();
                    },
                  ),
                  const Text('必填'),
                  IconButton(
                    tooltip: '删除参数',
                    onPressed: () {
                      setState(() => parameters.removeAt(i));
                      change();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: parameters.length >= 16
              ? null
              : () {
                  setState(
                    () => parameters.add({
                      'name': '',
                      'label': '',
                      'type': 'text',
                      'required': false,
                    }),
                  );
                  change();
                },
          icon: const Icon(Icons.add),
          label: const Text('添加参数'),
        ),
      ),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
