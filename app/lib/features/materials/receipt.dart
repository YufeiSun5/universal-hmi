import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'document_export.dart';
import 'widgets.dart';
import 'session.dart';

class MaterialReceipt extends StatefulWidget {
  const MaterialReceipt({
    super.key,
    required this.api,
    required this.record,
    required this.kind,
  });
  final PlatformApi api;
  final Json record;
  final String kind;

  @override
  State<MaterialReceipt> createState() => _MaterialReceiptState();
}

class _MaterialReceiptState extends State<MaterialReceipt> {
  bool busy = false;
  String? message, error;

  Future<void> export() async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final result = await exportMaterialDocument(widget.api, widget.record);
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) {
        setState(() => error = '导出失败，可重试；单据已保存，不会再次扣库存。$e');
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text('${materialKind(widget.kind)}已完成'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('单号：${widget.record['number']}'),
              const SizedBox(height: 12),
              Text(switch (widget.kind) {
                'inbound' => '已生成入库单并增加库存。',
                'outbound' => '已生成出库单并扣减库存，金额和签名已保存。',
                'return' => '已生成退库单并增加目标分类库存，原出库单保留。',
                _ => '已生成转类单并转移分类库存，总库存不变。',
              }),
              if (busy) const LinearProgressIndicator(),
              if (error != null) materialError(error!),
              if (message != null) Text(message!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('返回列表'),
        ),
        if (widget.kind == 'outbound')
          TextButton(
            onPressed: busy ? null : export,
            child: const Text('导出Excel出库单'),
          ),
        if (['inbound', 'outbound'].contains(widget.kind))
          OutlinedButton(
            onPressed: busy ? null : () => Navigator.pop(context, 'new'),
            child: const Text('继续新建'),
          ),
        FilledButton(
          onPressed: busy ? null : () => Navigator.pop(context, 'view'),
          child: const Text('查看单据'),
        ),
      ],
    ),
  );
}
