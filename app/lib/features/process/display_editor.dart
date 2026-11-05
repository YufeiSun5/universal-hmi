import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

class ProcessDisplayEditor extends StatefulWidget {
  const ProcessDisplayEditor({super.key, required this.node});
  final ScreenElement node;
  @override
  State<ProcessDisplayEditor> createState() => _ProcessDisplayEditorState();
}

class _ProcessDisplayEditorState extends State<ProcessDisplayEditor> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  bool get level => widget.node.kind == 'level';
  late String orientation;
  String? error;
  @override
  void initState() {
    super.initState();
    final config = level
        ? widget.node.levelDisplay!
        : widget.node.stateDisplay ??
              defaultStateDisplay(valve: widget.node.symbol.contains('valve'));
    for (final entry in config.entries) {
      if (entry.key != 'orientation') {
        fields[entry.key] = TextEditingController(text: '${entry.value}');
      }
    }
    orientation = config['orientation'] as String? ?? 'vertical';
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget input(
    String key,
    String label, {
    bool number = false,
    bool color = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: Key('display-$key'),
      controller: fields[key],
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      maxLength: number || color ? null : 32,
      decoration: InputDecoration(
        labelText: label,
        helperText: color ? '#RRGGBB，可点击右侧选择颜色' : null,
        suffixIcon: color
            ? PopupMenuButton<String>(
                tooltip: '$label选择',
                onSelected: (v) => setState(() => fields[key]!.text = v),
                itemBuilder: (_) => [
                  for (final entry in const {
                    '#16a34a': '绿色',
                    '#dc2626': '红色',
                    '#2563eb': '蓝色',
                    '#f59e0b': '橙色',
                    '#64748b': '灰色',
                  }.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: parseColor(entry.key),
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(entry.value),
                        ],
                      ),
                    ),
                ],
                icon: const Icon(Icons.palette_outlined),
              )
            : null,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (number) {
          final parsed = double.tryParse(text);
          return parsed == null || !parsed.isFinite ? '请输入有限数值' : null;
        }
        if (color) {
          return RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)
              ? null
              : '请输入 #RRGGBB 颜色';
        }
        return text.isEmpty ? '请填写状态文字' : null;
      },
    ),
  );

  void save() {
    if (!form.currentState!.validate()) return;
    final Json config = {
      for (final e in fields.entries)
        e.key:
            e.key.endsWith('_value') || e.key == 'minimum' || e.key == 'maximum'
            ? double.parse(e.value.text.trim())
            : e.value.text.trim(),
      if (level) 'orientation': orientation,
    };
    try {
      validateProcessDisplay(
        widget.node.update({level ? 'level_display' : 'state_display': config}),
      );
      Navigator.pop(context, config);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(level ? '比例柱量程' : '状态灯设置'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                level
                    ? '绑定输入使用点位工程值。百分比 =（当前值 − 下限）÷（上限 − 下限）。柱体限制在0–100%，超出量程仍显示真实百分比和越界提示。'
                    : '绑定真实状态反馈点。只匹配下方两个值（BOOL按1/0）；其他值、坏质量或断线均显示未知。颜色和文字由你确认，此处不发送设备命令。',
              ),
              const SizedBox(height: 20),
              if (level) ...[
                input('minimum', '下限（0%）', number: true),
                input('maximum', '上限（100%）', number: true),
                DropdownButtonFormField<String>(
                  initialValue: orientation,
                  decoration: const InputDecoration(labelText: '填充方向'),
                  items: const [
                    DropdownMenuItem(value: 'vertical', child: Text('竖向：从下向上')),
                    DropdownMenuItem(
                      value: 'horizontal',
                      child: Text('横向：从左向右'),
                    ),
                  ],
                  onChanged: (v) => setState(() => orientation = v!),
                ),
              ] else ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (final valve in [false, true])
                      OutlinedButton(
                        onPressed: () => setState(() {
                          for (final e in defaultStateDisplay(
                            valve: valve,
                          ).entries) {
                            fields[e.key]!.text = '${e.value}';
                          }
                          error = null;
                        }),
                        child: Text(valve ? '阀门预设（开 / 关）' : '泵预设（运行 / 停止）'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                input(
                  'active_value',
                  '${fields['active_text']!.text}对应值',
                  number: true,
                ),

                input(
                  'active_color',
                  '${fields['active_text']!.text}颜色',
                  color: true,
                ),
                const Divider(height: 24),
                input(
                  'inactive_value',
                  '${fields['inactive_text']!.text}对应值',
                  number: true,
                ),

                input(
                  'inactive_color',
                  '${fields['inactive_text']!.text}颜色',
                  color: true,
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
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
    ),
    actions: [
      if (!level && widget.node.stateDisplay != null)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, <String, dynamic>{'clear': true}),
          child: const Text('移除状态灯'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('返回'),
      ),
      FilledButton(onPressed: save, child: const Text('应用到草稿')),
    ],
  );
}
