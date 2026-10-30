import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

class EquipmentSignalsEditor extends StatefulWidget {
  const EquipmentSignalsEditor({
    super.key,
    required this.api,
    required this.initial,
    required this.onChanged,
    required this.enabled,
  });
  final PlatformApi api;
  final Json initial;
  final ValueChanged<Json> onChanged;
  final bool enabled;
  @override
  State<EquipmentSignalsEditor> createState() => _EquipmentSignalsEditorState();
}

class _EquipmentSignalsEditorState extends State<EquipmentSignalsEditor> {
  late Json signals = Map.of(widget.initial);
  final expressions = <String, TextEditingController>{};
  List<Json> points = [];
  String? error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    for (final key in ['fault', 'running']) {
      expressions[key] = TextEditingController(
        text: signals[key]?['expression'] as String? ?? 'x != 0',
      );
    }
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request('GET', '/api/v1/points');
      if (mounted) {
        setState(() {
          points = objects(
            result['items'],
          ).where((p) => p['data_type'] != 'STRING').toList();
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final c in expressions.values) {
      c.dispose();
    }
    super.dispose();
  }

  void update(String key, {String? id}) {
    setState(() {
      signals[key] = {
        'point_id': id ?? signals[key]?['point_id'],
        'expression': expressions[key]!.text.trim(),
      };
    });
    widget.onChanged(Map.of(signals));
  }

  Future<void> choose(String key) async {
    final p = await showDialog<Json>(
      context: context,
      builder: (_) => _PointPicker(points: points),
    );
    if (p != null && mounted) update(key, id: value(p, 'id'));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '自动状态（可选）',
        style: TextStyle(fontWeight: FontWeight.w700, color: ledgerInk),
      ),
      const SizedBox(height: 8),
      const Text(
        '故障优先显示。x 为所选变量的工程值，开关量按 1 / 0 判断；未绑定或数据无效时不会显示为正常。',
        style: TextStyle(fontSize: 12, color: Color(0xff647987)),
      ),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Row(
          children: [
            Expanded(child: Text('变量目录加载失败：$error')),
            TextButton(onPressed: load, child: const Text('重试')),
          ],
        ),
      for (final key in ['fault', 'running'])
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    key == 'fault' ? '故障条件' : '运行条件',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  TextButton(
                    key: Key('equipment-bind-$key'),
                    onPressed: widget.enabled && !loading && error == null
                        ? () => choose(key)
                        : null,
                    child: const Text('选择变量'),
                  ),
                  if (signals[key] != null)
                    TextButton(
                      onPressed: widget.enabled
                          ? () {
                              setState(() => signals.remove(key));
                              widget.onChanged(Map.of(signals));
                            }
                          : null,
                      child: const Text('解除'),
                    ),
                ],
              ),
              if (signals[key] == null)
                const Text(
                  '未绑定',
                  style: TextStyle(fontSize: 12, color: Color(0xff8294a0)),
                )
              else ...[
                Builder(
                  builder: (_) {
                    final id = signals[key]['point_id'];
                    final matches = points.where((p) => p['id'] == id);
                    return Text(
                      matches.isEmpty
                          ? '变量不可用 · $id'
                          : '${matches.first['station']} / ${matches.first['name']} · $id',
                      style: const TextStyle(fontSize: 12),
                    );
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: Key('equipment-expression-$key'),
                  controller: expressions[key],
                  enabled: widget.enabled,
                  decoration: const InputDecoration(
                    labelText: '成立条件',
                    hintText: 'x >= 0.5 && x <= 100',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (s) =>
                      s == null || s.trim().isEmpty ? '请填写判断条件' : null,
                  onChanged: (_) => update(key),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (label, expression) in [
                      ('非零成立', 'x != 0'),
                      ('零值成立', 'x == 0'),
                      ('区间示例', 'x >= 0.5 && x <= 100'),
                    ])
                      TextButton(
                        onPressed: widget.enabled
                            ? () {
                                expressions[key]!.text = expression;
                                update(key);
                              }
                            : null,
                        child: Text(
                          label,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
    ],
  );
}

class _PointPicker extends StatefulWidget {
  const _PointPicker({required this.points});
  final List<Json> points;
  @override
  State<_PointPicker> createState() => _PointPickerState();
}

class _PointPickerState extends State<_PointPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final rows = widget.points
        .where(
          (p) => '${p['station']} ${p['name']} ${p['id']}'
              .toLowerCase()
              .contains(query.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      title: const Text('选择状态变量'),
      content: SizedBox(
        width: 520,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: '搜索站点、变量名称或 ID'),
              onChanged: (s) => setState(() => query = s),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('没有匹配变量'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final p = rows[i];
                        return ListTile(
                          dense: true,
                          title: Text('${p['station']} / ${p['name']}'),
                          subtitle: Text(
                            '${p['id']} · ${p['data_type']} ${p['unit'] ?? ''}',
                          ),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
