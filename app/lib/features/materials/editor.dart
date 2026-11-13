import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../platform/material_files.dart';
import 'session.dart';
import 'widgets.dart';

Future<Json?> editMaterial(
  BuildContext context,
  PlatformApi api,
  MaterialsSession session, {
  required String kind,
  Json seed = const {},
  bool canCatalog = false,
  String? draftKey,
}) => showDialog<Json>(
  context: context,
  barrierDismissible: false,
  builder: (_) => MaterialEditor(
    api: api,
    session: session,
    kind: kind,
    seed: seed,
    canCatalog: canCatalog,
    draftKey: draftKey,
  ),
);

class MaterialEditor extends StatefulWidget {
  const MaterialEditor({
    super.key,
    required this.api,
    required this.session,
    required this.kind,
    this.seed = const {},
    this.canCatalog = false,
    this.draftKey,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final String kind;
  final Json seed;
  final bool canCatalog;
  final String? draftKey;
  @override
  State<MaterialEditor> createState() => _MaterialEditorState();
}

class _MaterialEditorState extends State<MaterialEditor> {
  late final String keyName =
      widget.draftKey ?? '${widget.kind}-${widget.seed['id'] ?? 'new'}';
  late final MaterialDraft draft = widget.session.draft(keyName);
  final controllers = <String, TextEditingController>{};
  bool busy = false;
  String? error;
  Json? preview;
  bool get locked => busy || draft.pending != null;
  String get kind => widget.kind;
  String get title => const {
    'category': '分类',
    'item': '物料档案',
    'application': '采购申请',
    'inbound': '入库',
    'outbound': '出库',
    'return': '退库',
    'transfer': '品类转移',
  }[kind]!;
  bool get document =>
      const ['inbound', 'outbound', 'return', 'transfer'].contains(kind);
  @override
  void initState() {
    super.initState();
    if (draft.values.isEmpty) {
      draft.values = {...widget.seed};
      if (kind == 'outbound') {
        draft.values.putIfAbsent('purpose', () => '日常维修领用');
      }
      if (kind == 'item') draft.values.putIfAbsent('warning', () => '0');
      if (kind == 'category' &&
          materialText(draft.values, 'parent_id').isNotEmpty) {
        final path = materialText(draft.values, 'path').split(' / ');
        if (path.length > 1) {
          draft.values['parent_name'] = path.take(path.length - 1).join(' / ');
        }
      }
      if (kind == 'transfer' && widget.seed['stock_category_id'] != null) {
        final v = widget.seed;
        draft.lines.add({
          'key': materialOperationID(),
          'item_id': v['id'],
          'name': v['name'],
          'specification': v['specification'],
          'unit': v['unit'],
          'category_id': v['stock_category_id'],
          'category_name': v['stock_category'],
          'quantity': '1',
          'item_version': v['version'],
          'balance_version': v['balance_version'],
          'target_category_id': '',
          'target_category': '',
        });
      }
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController controller(String key, String value) =>
      controllers.putIfAbsent(key, () => TextEditingController(text: value));
  void change(VoidCallback work) {
    setState(() {
      work();
      preview = null;
      draft.changed();
    });
  }

  Widget field(
    String name,
    String label, {
    bool required = false,
    int max = 200,
    int lines = 1,
    bool decimal = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      key: ValueKey('material-field-$name'),
      controller: controller(name, materialText(draft.values, name)),
      enabled: !locked,
      maxLines: lines,
      maxLength: max,
      keyboardType: decimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : lines > 1
          ? TextInputType.multiline
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: '$label${required ? ' *' : ''}',
        counterText: '',
        helperText: decimal ? '最多4位小数' : null,
      ),
      onChanged: (v) => change(() => draft.values[name] = v),
    ),
  );
  Future<void> chooseCategory({
    Json? line,
    bool target = false,
    bool parent = false,
  }) async {
    final chosen = await pickMaterialRecord(
      context,
      widget.api,
      title: '选择分类',
      endpoint: '$materialsBase/categories',
      label: categoryLabel,
    );
    if (chosen == null || !mounted) return;
    final key = target
        ? 'target_category_id'
        : parent
        ? 'parent_id'
        : 'category_id';
    final label = target
        ? 'target_category'
        : parent
        ? 'parent_name'
        : 'category_name';
    change(() {
      (line ?? draft.values)[key] = chosen['id'];
      (line ?? draft.values)[label] = categoryLabel(chosen);
    });
  }

  Widget categoryButton({
    Json? line,
    bool target = false,
    bool parent = false,
  }) {
    final data = line ?? draft.values;
    final label = target
        ? 'target_category'
        : parent
        ? 'parent_name'
        : 'category_name';
    final name = materialText(data, label);
    final prompt = target
        ? '目标分类'
        : parent
        ? '上级分类'
        : '入库分类';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: locked
                  ? null
                  : () => chooseCategory(
                      line: line,
                      target: target,
                      parent: parent,
                    ),
              child: Text(
                '$prompt：${name.isEmpty ? (parent ? '根分类' : '请选择') : name}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (parent && materialText(data, 'parent_id').isNotEmpty)
            IconButton(
              tooltip: '设为根分类',
              onPressed: locked
                  ? null
                  : () => change(() {
                      data['parent_id'] = '';
                      data['parent_name'] = '';
                    }),
              icon: const Icon(Icons.clear),
            ),
        ],
      ),
    );
  }

  Future<void> addLine() async {
    Json? item;
    if (kind == 'return') {
      final lines = objects(
        widget.seed['lines'],
      ).where((l) => l['remaining'] != '0').toList();
      item = await showDialog<Json>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('选择原出库明细'),
          children: [
            for (final line in lines)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, line),
                child: Text(
                  '${line['name']} · 可退 ${line['remaining']} ${line['unit']}',
                ),
              ),
          ],
        ),
      );
    } else {
      final stock = kind == 'outbound' || kind == 'transfer';
      item = await pickMaterialRecord(
        context,
        widget.api,
        title: stock ? '选择库存物料' : '选择物料',
        endpoint: '$materialsBase/${stock ? 'stock' : 'items'}',
        label: (v) =>
            '${itemLabel(v)}${stock ? ' · ${v['stock_category']} · 库存 ${v['quantity']}' : ''}',
      );
    }
    if (item == null || !mounted) return;
    final v = item;
    change(
      () => draft.lines.add({
        'key': materialOperationID(),
        'item_id': kind == 'return' ? v['item_id'] : v['id'],
        'source_line_id': kind == 'return' ? v['id'] : '',
        'name': v['name'],
        'specification': v['specification'],
        'unit': v['unit'],
        'category_id': v['stock_category_id'] ?? v['category_id'],
        'category_name':
            v['stock_category'] ?? v['category_name'] ?? v['category'] ?? '',
        'target_category_id': kind == 'return' ? v['category_id'] : '',
        'target_category': kind == 'return' ? v['category'] : '',
        'quantity': '1',
        'price': kind == 'inbound' ? (v['price'] ?? '') : '',
        'remaining': v['remaining'],
        'item_version': v['version'] ?? 0,
        'balance_version': v['balance_version'] ?? 0,
      }),
    );
  }

  Future<void> pickApplication() async {
    final chosen = await pickMaterialRecord(
      context,
      widget.api,
      title: '选择已通过的采购申请',
      endpoint: '$materialsBase/applications',
      query: const {'status': 'approved'},
      label: (v) => '${v['number']} · ${v['owner']}\n${v['text']}',
    );
    if (chosen != null && mounted) {
      change(() {
        draft.values['application_id'] = chosen['id'];
        draft.values['application_version'] = chosen['version'];
        draft.values['application_label'] =
            '${chosen['number']} · ${chosen['text']}';
      });
    }
  }

  Future<void> pickImages() async {
    try {
      final files = await pickMaterialImages();
      if (!mounted) return;
      if (files.length + draft.images.length > 10) {
        throw const FormatException('每单最多10张图片');
      }
      change(() => draft.images.addAll(files.map(MaterialImageDraft.new)));
      await uploadImages();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> uploadImages() async {
    if (busy) return;
    setState(() => busy = true);
    for (final image in draft.images.where((v) => v.assetID == null)) {
      if (!mounted) break;
      setState(() {
        image.uploading = true;
        image.error = null;
      });
      try {
        final v = await widget.api.request(
          'POST',
          '$materialsBase/assets',
          body: {
            'operation_id': image.operation,
            'kind': 'receipt',
            'name': image.file.name,
            'data': base64Encode(image.file.bytes),
          },
        );
        image.assetID = materialText(v, 'id');
      } catch (e) {
        image.error = '$e';
      }
      image.uploading = false;
    }
    if (mounted) setState(() => busy = false);
  }

  Widget lineEditor(Json line) {
    final key = materialText(line, 'key');
    Widget number(String field, String label) => TextField(
      key: ValueKey('material-line-$field-$key'),
      controller: controller('$key-$field', materialText(line, field)),
      enabled: !locked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
      onChanged: (v) => change(() => line[field] = v),
    );
    return Container(
      key: ValueKey(key),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffc6ced6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${line['name']} · ${line['specification'] ?? ''} (${line['unit']})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '移除明细',
                onPressed: locked
                    ? null
                    : () => change(() => draft.lines.remove(line)),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (kind == 'inbound')
            categoryButton(line: line)
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '原分类：${line['category_name']}${kind == 'return' ? ' · 剩余可退 ${line['remaining']}' : ''}',
              ),
            ),
          if (kind == 'transfer' || kind == 'return')
            categoryButton(line: line, target: true),
          Row(
            children: [
              Expanded(
                child: number('quantity', kind == 'return' ? '本次退库数量' : '数量'),
              ),
              if (kind == 'inbound') ...[
                const SizedBox(width: 12),
                Expanded(child: number('price', '入库单价（选填）')),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Json payload() {
    final v = draft.values;
    if (kind == 'category') {
      return {
        'id': v['id'] ?? '',
        'version': v['version'] ?? 0,
        'name': v['name'] ?? '',
        'parent_id': v['parent_id'] ?? '',
      };
    }
    if (kind == 'item') {
      return {
        for (final k in [
          'id',
          'name',
          'specification',
          'unit',
          'category_id',
          'price',
          'warning',
        ])
          k: v[k] ?? '',
        'version': v['version'] ?? 0,
      };
    }
    if (kind == 'application') {
      return {
        'id': v['id'] ?? '',
        'version': v['version'] ?? 0,
        'text': v['text'] ?? '',
      };
    }
    return {
      'purpose': v['purpose'] ?? '',
      'recipient': v['recipient'] ?? '',
      'notes': v['notes'] ?? '',
      'application_id': v['application_id'] ?? '',
      'application_version': v['application_version'] ?? 0,
      'source_id': kind == 'return' ? widget.seed['id'] : '',
      'lines': draft.lines
          .map(
            (l) => <String, dynamic>{
              for (final k in [
                'item_id',
                'category_id',
                'quantity',
                'price',
                'source_line_id',
                'target_category_id',
              ])
                k: l[k] ?? '',
              'item_version': l['item_version'] ?? 0,
              'balance_version': l['balance_version'] ?? 0,
            },
          )
          .toList(),
      'asset_ids': draft.images
          .map((i) => i.assetID)
          .whereType<String>()
          .toList(),
    };
  }

  Future<void> submit() async {
    if (busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (kind == 'inbound' && draft.images.any((i) => i.assetID == null)) {
      setState(() => error = '有图片未上传成功，请重试或明确移除后再确认。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var body = payload();
      if (draft.pending == null) {
        if (kind == 'outbound') {
          final data = await widget.api.request(
            'POST',
            '$materialsBase/outbound-preview',
            body: body,
          );
          if (!mounted) return;
          setState(() => preview = data);
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('确认出库'),
              content: SizedBox(
                width: 620,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final line in objects(data['lines']))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '${line['name']} · ${line['category']}\n${line['quantity']} ${line['unit']} × ${materialText(line, 'price').isEmpty ? '未填单价' : line['price']} = ${materialText(line, 'amount').isEmpty ? '—' : line['amount']}',
                          ),
                        ),
                      Text(
                        '${data['missing_prices'] == 0 ? '合计金额' : '已知金额小计'}：${data['known_amount']}${data['missing_prices'] == 0 ? '' : '；缺价 ${data['missing_prices']} 行'}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      MaterialAssetView(
                        api: widget.api,
                        id: materialText(data['signature'] as Json, 'asset_id'),
                        height: 80,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('返回修改'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('确认扣减库存'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          body = {
            ...body,
            'lines': data['inputs'],
            'signature_version': data['signature']['version'],
          };
        } else if (kind == 'return') {
          final sig = await widget.api.request(
            'GET',
            '/api/v1/account/signature',
          );
          if (materialText(sig, 'asset_id').isEmpty) {
            throw StateError('请先在个人账号上传签名');
          }
          body = {...body, 'signature_version': sig['version']};
          if (!mounted ||
              !await materialConfirm(
                context,
                '确认退库',
                '退回数量将加入所选分类，并保留原出库记录。',
              )) {
            return;
          }
        } else if (document) {
          if (!mounted ||
              !await materialConfirm(
                context,
                '确认$title',
                kind == 'transfer' ? '将所填数量转至目标分类，总库存不变。' : '确认后增加库存并生成正式入库单。',
              )) {
            return;
          }
        }
      }
      final path =
          '$materialsBase/${const {'category': 'categories', 'item': 'items', 'application': 'applications'}[kind] ?? kind}';
      final result = await draft.submit(widget.api, path, body);
      widget.session.clear(keyName);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() async {
    if (busy) return;
    if (draft.dirty || draft.pending != null) {
      if (!await materialConfirm(
        context,
        '保留草稿并返回？',
        draft.pending != null
            ? '操作结果尚未确认。草稿和原操作ID会保留，重新打开后请重试确认，避免重复记账。'
            : '未提交内容会保留在当前会话，重新打开可继续；刷新或退出将丢失。',
      )) {
        return;
      }
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> quickCreate(String type) async {
    final result = await editMaterial(
      context,
      widget.api,
      widget.session,
      kind: type,
      canCatalog: true,
      draftKey: 'quick-$type',
    );
    if (result != null && mounted && type == 'item') {
      change(
        () => draft.lines.add({
          'key': materialOperationID(),
          'item_id': result['id'],
          'name': result['name'],
          'specification': result['specification'],
          'unit': result['unit'],
          'category_id': result['category_id'],
          'category_name': result['category_name'] ?? '已选默认分类',
          'quantity': '1',
          'price': result['price'] ?? '',
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (popped, result) {
      if (!popped) close();
    },
    child: Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.seed.isEmpty ? '新建' : '办理'}$title',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '保留并返回',
                    onPressed: busy ? null : close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (busy) const LinearProgressIndicator(),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null) materialError(error!),
                      if (draft.pending != null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('提交结果待确认；输入已保留，请使用原操作重试。'),
                        ),
                      if (kind == 'category') ...[
                        field('name', '分类名称', required: true, max: 100),
                        categoryButton(parent: true),
                      ],
                      if (kind == 'item') ...[
                        field('name', '物料名称', required: true),
                        field('specification', '规格'),
                        field('unit', '计量单位', required: true, max: 30),
                        categoryButton(),
                        field('price', '参考单价（选填）', decimal: true, max: 16),
                        field(
                          'warning',
                          '库存预警值',
                          required: true,
                          decimal: true,
                          max: 16,
                        ),
                      ],
                      if (kind == 'application')
                        field(
                          'text',
                          '采购需求',
                          required: true,
                          max: 10000,
                          lines: 7,
                        ),
                      if (kind == 'inbound') ...[
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: locked ? null : pickApplication,
                                child: Text(
                                  materialText(
                                        draft.values,
                                        'application_id',
                                      ).isEmpty
                                      ? '独立入库 · 可选择已批准申请'
                                      : materialText(
                                          draft.values,
                                          'application_label',
                                        ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (materialText(
                              draft.values,
                              'application_id',
                            ).isNotEmpty)
                              IconButton(
                                tooltip: '改为独立入库',
                                onPressed: locked
                                    ? null
                                    : () => change(() {
                                        draft.values['application_id'] = '';
                                        draft.values['application_version'] = 0;
                                      }),
                                icon: const Icon(Icons.clear),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (kind == 'return')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text('原出库单：${widget.seed['number']}'),
                        ),
                      if (document) ...[
                        for (final line in draft.lines) lineEditor(line),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: locked ? null : addLine,
                              icon: const Icon(Icons.add),
                              label: const Text('添加物料'),
                            ),
                            if (kind == 'inbound' && widget.canCatalog) ...[
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () => quickCreate('item'),
                                child: const Text('快速新建物料'),
                              ),
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () => quickCreate('category'),
                                child: const Text('快速新建分类'),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (kind == 'outbound') ...[
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final purpose in ['日常维修领用', '应急抢修', '其他'])
                              ActionChip(
                                label: Text(purpose),
                                onPressed: locked
                                    ? null
                                    : () => change(() {
                                        draft.values['purpose'] =
                                            purpose == '其他' ? '' : purpose;
                                        controller(
                                          'purpose',
                                          '',
                                        ).text = materialText(
                                          draft.values,
                                          'purpose',
                                        );
                                      }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        field(
                          'purpose',
                          '用途',
                          required: true,
                          max: 1000,
                          lines: 2,
                        ),
                        field('recipient', '领料人（选填）'),
                      ],
                      if (document)
                        field('notes', '备注（选填）', max: 2000, lines: 2),
                      if (kind == 'inbound') ...[
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: locked ? null : pickImages,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: Text('添加清单照片（${draft.images.length}/10）'),
                            ),
                            if (draft.images.any((i) => i.assetID == null))
                              TextButton(
                                onPressed: locked ? null : uploadImages,
                                child: const Text('重试上传'),
                              ),
                          ],
                        ),
                        for (final image in draft.images)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Image.memory(
                              image.file.bytes,
                              width: 48,
                              height: 48,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                            title: Text(
                              image.file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              image.uploading
                                  ? '上传中'
                                  : image.error ??
                                        (image.assetID != null
                                            ? '已上传'
                                            : '等待上传'),
                              style: TextStyle(
                                color: image.error != null
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: '移除图片',
                              onPressed: locked
                                  ? null
                                  : () => change(
                                      () => draft.images.remove(image),
                                    ),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (kind == 'outbound' || kind == 'return')
                    MaterialAccountLink(
                      session: widget.session,
                      enabled: !locked,
                    ),
                  TextButton(
                    onPressed: busy ? null : close,
                    child: const Text('保留并返回'),
                  ),
                  if (draft.dirty && draft.pending == null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (await materialConfirm(
                                context,
                                '放弃草稿？',
                                '将清除当前未提交输入，已保存的正式记录不受影响。',
                              )) {
                                widget.session.clear(keyName);
                                if (context.mounted) Navigator.pop(context);
                              }
                            },
                      child: const Text('放弃草稿'),
                    ),
                  FilledButton(
                    key: const Key('material-submit'),
                    onPressed: busy ? null : submit,
                    child: Text(
                      draft.pending != null
                          ? '重试确认结果'
                          : kind == 'outbound'
                          ? '核对并出库'
                          : document
                          ? '确认$title'
                          : '提交保存',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
