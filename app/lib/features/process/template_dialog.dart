import 'package:flutter/material.dart';
import 'model.dart';
import 'templates.dart';

class ProcessTemplateDialog extends StatefulWidget {
  const ProcessTemplateDialog({super.key, required this.station});
  final String station;
  @override
  State<ProcessTemplateDialog> createState() => _ProcessTemplateDialogState();
}

class _ProcessTemplateDialogState extends State<ProcessTemplateDialog> {
  final name = TextEditingController(text: '未命名模板');
  final width = TextEditingController(text: '1280');
  final height = TextEditingController(text: '660');
  String source = 'blank';
  String? error;
  bool busy = false;
  @override
  void dispose() {
    name.dispose();
    width.dispose();
    height.dispose();
    super.dispose();
  }

  Future<void> create() async {
    final w = double.tryParse(width.text), h = double.tryParse(height.text);
    if (name.text.trim().isEmpty ||
        name.text.trim().length > 80 ||
        w == null ||
        h == null ||
        !w.isFinite ||
        !h.isFinite ||
        w < 320 ||
        h < 240 ||
        w > 8192 ||
        h > 8192) {
      setState(() => error = '填写模板名称；画布宽 320–8192，高 240–8192。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final doc = source == 'heating'
          ? await ProcessTemplates.heatingStation(widget.station)
          : ScreenDocument.empty(widget.station).copy(width: w, height: h);
      if (mounted) Navigator.pop(context, doc.copy(name: name.text.trim()));
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '创建失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建模板'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('template-name'),
              controller: name,
              enabled: !busy,
              maxLength: 80,
              decoration: const InputDecoration(labelText: '模板名称'),
            ),
            DropdownButtonFormField<String>(
              key: const Key('template-source'),
              initialValue: source,
              decoration: const InputDecoration(labelText: '起始内容'),
              items: const [
                DropdownMenuItem(value: 'blank', child: Text('空白模板')),
                DropdownMenuItem(value: 'heating', child: Text('三换热器供热站（参考图）')),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      source = value!;
                      if (source == 'heating') {
                        name.text = '三换热器供热站';
                        width.text = '1280';
                        height.text = '660';
                      }
                    }),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('template-width'),
                    controller: width,
                    enabled: !busy && source == 'blank',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '画布宽度'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('template-height'),
                    controller: height,
                    enabled: !busy && source == 'blank',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '画布高度'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '创建后可编辑设备、管道、文字和变量。保存后归属当前目标站，其他站可引用副本。',
              style: TextStyle(fontSize: 12),
            ),
            if (error != null)
              Text(
                error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
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
        key: const Key('template-create'),
        onPressed: busy ? null : create,
        child: Text(busy ? '创建中…' : '创建'),
      ),
    ],
  );
}
