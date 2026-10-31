import 'package:flutter/material.dart';
import '../../shared/api.dart';

class ArrowRuleEditor extends StatefulWidget {
  const ArrowRuleEditor({
    super.key,
    required this.title,
    required this.rule,
    required this.definitions,
    required this.station,
    required this.template,
    required this.onPickPoint,
  });
  final String title, station;
  final Json? rule;
  final Map<String, Json> definitions;
  final bool template;
  final Future<String?> Function() onPickPoint;
  @override
  State<ArrowRuleEditor> createState() => _ArrowRuleEditorState();
}

class _ArrowRuleEditorState extends State<ArrowRuleEditor> {
  late String match = widget.rule?['match'] as String? ?? 'all';
  late final rows = [
    for (final c in objects(widget.rule?['conditions']))
      Map<String, dynamic>.of(c),
  ];
  final form = GlobalKey<FormState>();
  int identity = 0;
  @override
  void initState() {
    super.initState();
    if (rows.isEmpty) add();
  }

  void add() => rows.add({
    'slot': '条件变量${rows.length + 1}',
    'point_id': '',
    'operator': '>',
    'value': 0.0,
    '_key': identity++,
  });
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 640,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.template
                      ? '模板仅保存变量占位和比较条件，实例化后绑定实际点位。'
                      : '选择授权变量（可跨站）；全部输入须在线且质量正常。BOOL 用 1 / 0 比较。',
                ),
                DropdownButton<String>(
                  value: match,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部满足（AND）')),
                    DropdownMenuItem(value: 'any', child: Text('任一满足（OR）')),
                  ],
                  onChanged: (v) => setState(() => match = v!),
                ),
                for (final c in rows)
                  Padding(
                    key: ObjectKey(c),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      children: [
                        TextFormField(
                          initialValue: c['slot'] as String? ?? '',
                          decoration: const InputDecoration(
                            labelText: '变量占位名称',
                          ),
                          maxLength: 64,
                          onChanged: (v) => c['slot'] = v,
                        ),
                        if (!widget.template)
                          OutlinedButton(
                            onPressed: () async {
                              final id = await widget.onPickPoint();
                              if (mounted && id != null) {
                                setState(() => c['point_id'] = id);
                              }
                            },
                            child: Text(
                              c['point_id'] == ''
                                  ? '绑定实例点位'
                                  : '${widget.definitions[c['point_id']]?['name'] ?? '点位缺失'} · ${c['point_id']}',
                            ),
                          ),
                        Row(
                          children: [
                            DropdownButton<String>(
                              value: c['operator'] as String,
                              items: [
                                for (final op in [
                                  '>',
                                  '<',
                                  '>=',
                                  '<=',
                                  '==',
                                  '!=',
                                ])
                                  DropdownMenuItem(value: op, child: Text(op)),
                              ],
                              onChanged: (v) =>
                                  setState(() => c['operator'] = v),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: '${c['value']}',
                                decoration: const InputDecoration(
                                  labelText: '比较值',
                                ),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                      signed: true,
                                    ),
                                validator: (v) =>
                                    double.tryParse(v ?? '')?.isFinite == true
                                    ? null
                                    : '请输入有限数值',
                                onChanged: (v) =>
                                    c['value'] = double.tryParse(v),
                              ),
                            ),
                            IconButton(
                              tooltip: '删除条件',
                              onPressed: rows.length > 1
                                  ? () => setState(() => rows.remove(c))
                                  : null,
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                TextButton.icon(
                  onPressed: rows.length < 8 ? () => setState(add) : null,
                  icon: const Icon(Icons.add),
                  label: const Text('添加比较条件（最多 8 项）'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, <String, dynamic>{'clear': true}),
          child: const Text('清除条件'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop(context, <String, dynamic>{
              'match': match,
              'conditions': [
                for (final c in rows)
                  {
                    'slot': c['slot'],
                    'point_id': widget.template ? '' : c['point_id'],
                    'operator': c['operator'],
                    'value': c['value'],
                  },
              ],
            });
          },
          child: const Text('应用条件'),
        ),
      ],
    );
  }
}
