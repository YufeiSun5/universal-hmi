import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../platform/material_files.dart';
import 'session.dart';
import 'widgets.dart';
import 'form_guidance.dart';

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
  final fieldErrors = <String, String>{};
  final anchors = <String, GlobalKey>{};
  GlobalKey anchor(String key) => anchors.putIfAbsent(key, GlobalKey.new);
  void focusError(String key) {
    final target = anchors[key]?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 180),
        alignment: .2,
      );
    }
  }

  bool validate() {
    final errors = <String, String>{};
    void required(String key, String label) {
      if (materialText(draft.values, key).trim().isEmpty) {
        errors[key] = '请填写$label';
      }
    }

    void numeric(String key, String label, {bool optional = false}) {
      final e = materialNumberError(
        materialText(draft.values, key),
        optional: optional,
      );
      if (e != null) errors[key] = '$label：$e';
    }

    if (kind == 'category' || kind == 'item') {
      required('name', kind == 'category' ? '分类名称' : '物料名称');
    }
    if (kind == 'application') required('text', '采购需求与用途');
    if (kind == 'item') {
      required('unit', '计量单位');
      numeric('warning', '库存预警值');
      numeric('price', '参考单价', optional: true);
      if (materialText(draft.values, 'category_id').isEmpty) {
        errors['category_id'] = '请选择物料默认分类';
      }
    }
    if (kind == 'outbound') required('purpose', '用途');
    if (document && draft.lines.isEmpty) errors['lines'] = '请先添加至少一项物料';
    final seen = <String>{};
    for (final line in draft.lines) {
      final key = materialText(line, 'key');
      final label = materialText(line, 'name');
      final numberError = materialNumberError(
        materialText(line, 'quantity'),
        positive: true,
      );
      if (numberError != null) errors['$key-quantity'] = '$label：$numberError';
      final n = materialScaled(materialText(line, 'quantity'));
      final available = materialScaled(
        materialText(line, kind == 'return' ? 'remaining' : 'available'),
      );
      if (n != null &&
          available != null &&
          kind != 'inbound' &&
          n > available) {
        errors['$key-quantity'] =
            '$label：本次最多${materialUnscaled(available)} ${line['unit']}';
      }
      if (kind == 'inbound') {
        final e = materialNumberError(
          materialText(line, 'price'),
          optional: true,
        );
        if (e != null) errors['$key-price'] = '$label单价：$e';
        if (materialText(line, 'category_id').isEmpty) {
          errors['$key-category_id'] = '$label：请选择入库分类';
        }
      }
      if (kind == 'return' || kind == 'transfer') {
        if (materialText(line, 'target_category_id').isEmpty) {
          errors['$key-target_category_id'] = '$label：请选择有效目标分类';
        }
        if (kind == 'transfer' &&
            line['target_category_id'] == line['category_id']) {
          errors['$key-target_category_id'] = '$label：来源和目标分类不能相同';
        }
      }
      final identity = kind == 'return'
          ? '${line['source_line_id']}'
          : '${line['item_id']}/${line['category_id']}';
      if (!seen.add(identity)) {
        errors['$key-quantity'] = '$label重复，请将相同物料和分类合并为一条明细';
      }
    }
    setState(() {
      fieldErrors.clear();
      fieldErrors.addAll(errors);
      error = null;
    });
    if (errors.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusError(errors.keys.first);
      });
    }
    return errors.isEmpty;
  }

  String get guide => switch (kind) {
    'category' => '填写名称并选择上级；根分类无需选择上级。创建后可继续添加子分类。',
    'item' => '先选择默认分类，再填写名称与单位。参考单价用于后续出库快照，留空会提示缺价。',
    'application' => '写清需要什么、数量或规格、用途。提交后等待审批；驳回后可修改重提。',
    'inbound' => '①选择物料与入库分类  →  ②填写数量、单价及凭证  →  ③核对后增加库存',
    'outbound' => '①选择有库存的物料  →  ②填写数量与用途  →  ③核对金额和本人签名后扣减库存',
    'return' => '①选择原出库明细  →  ②填写退库数量及目标分类  →  ③核对后退回库存',
    _ => '①选择来源库存  →  ②填写数量及目标分类  →  ③核对后转移，总库存不变',
  };
  String? fieldHint(String key) => switch (key) {
    'name' => kind == 'category' ? '例如：阀门、管材、维修备件' : '例如：铜球阀；规格在下方单独填写',
    'specification' => '选填，例如：DN25、PN16',
    'unit' => '例如：个、米、吨。有业务后不能更改单位或规格',
    'price' => '选填；不填表示缺价，0表示免费。最多4位小数',
    'warning' => '总库存小于或等于此值时提醒；允许0，最多4位小数',
    'text' => '例如：泵房维修需DN25球阀10个，用于更换漏水阀门',
    'purpose' => '可选上方常用用途，也可直接填写具体使用位置与原因',
    'recipient' => '选填，实际领用的个人、班组或单位',
    'notes' => '选填，补充说明不会改变库存计算',
    _ => null,
  };
  Widget sectionTitle(String title, String help) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(
          help,
          style: const TextStyle(color: Color(0xff647581), fontSize: 12),
        ),
      ],
    ),
  );
  Future<bool> confirmDetails() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('核对$title'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(kind == 'transfer' ? '只转移分类，总库存不变。' : '确认后增加库存并生成正式单据。'),
                  const SizedBox(height: 12),
                  for (final l in draft.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '${l['name']} · ${l['specification'] ?? ''}\n本次 ${l['quantity']} ${l['unit']} · ${l['category_name']}${['transfer', 'return'].contains(kind) ? ' → ${l['target_category']}' : ''}${kind == 'inbound' ? '\n入库单价：${materialText(l, 'price').isEmpty ? '未填（缺价）' : l['price']}' : ''}',
                      ),
                    ),
                  if (kind == 'inbound')
                    Text(
                      '凭证照片：${draft.images.length} 张；${materialText(draft.values, 'application_id').isEmpty ? '独立入库' : '关联申请：${draft.values['application_label']}'}',
                    ),
                  if (kind == 'return') const Text('自动附本人当前签名，历史出库单与签名保持。'),
                  if (materialText(draft.values, 'notes').isNotEmpty)
                    Text('备注：${draft.values['notes']}'),
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
              child: Text(kind == 'transfer' ? '确认转移库存' : '确认$title并增加库存'),
            ),
          ],
        ),
      ) ??
      false;

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
          'available': v['quantity'],
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
    key: anchor(name),
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
        helperText: fieldHint(name) ?? (decimal ? '最多4位小数' : null),
        helperMaxLines: 3,
        errorText: fieldErrors[name],
        errorMaxLines: 3,
      ),
      onChanged: (v) => change(() {
        draft.values[name] = v;
        fieldErrors.remove(name);
      }),
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
      fieldErrors.remove(line == null ? key : '${line['key']}-$key');
    });
    if (line != null && target) {
      try {
        final data = await widget.api.request(
          'GET',
          '$materialsBase/stock',
          query: {
            'item_id': line['item_id'],
            'category_id': chosen['id'],
            'limit': 200,
          },
        );
        if (!mounted || line[key] != chosen['id']) return;
        final exact = objects(
          data['items'],
        ).where((v) => v['stock_category_id'] == chosen['id']).firstOrNull;
        setState(() => line['target_available'] = exact?['quantity'] ?? '0');
      } catch (e) {
        if (mounted) setState(() => error = '目标库存暂时无法读取，请重新选择目标分类：$e');
      }
    }
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
    final fieldKey = target
        ? 'target_category_id'
        : parent
        ? 'parent_id'
        : 'category_id';
    final errorKey = line == null ? fieldKey : '${line['key']}-$fieldKey';
    final prompt = target
        ? '目标分类'
        : parent
        ? '上级分类'
        : kind == 'item'
        ? '默认分类'
        : '入库分类';
    return Padding(
      key: anchor(errorKey),
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
                '$prompt：${name.isEmpty ? (parent ? '根分类' : '请选择') : name}${fieldErrors[errorKey] == null ? '' : '\n${fieldErrors[errorKey]}'}',
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
        'category_id':
            v['stock_category_id'] ??
            (kind == 'inbound' &&
                    materialText(draft.values, 'category_id').isNotEmpty
                ? draft.values['category_id']
                : v['category_id']),
        'category_name':
            v['stock_category'] ??
            (kind == 'inbound' &&
                    materialText(draft.values, 'category_id').isNotEmpty
                ? draft.values['category_name']
                : v['category_name'] ?? v['category'] ?? ''),
        'target_category_id': '',
        'target_category': '',
        'quantity': '1',
        'price': kind == 'inbound' ? (v['price'] ?? '') : '',
        'remaining': v['remaining'],
        'original_quantity': v['quantity'],
        'returned': v['returned'],
        'available': v['quantity'],
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
    Widget number(String field, String label) => Container(
      key: anchor('$key-$field'),
      child: TextField(
        key: ValueKey('material-line-$field-$key'),
        controller: controller('$key-$field', materialText(line, field)),
        enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText:
              '$label${field == 'quantity' ? '（${line['unit']}） *' : ''}',
          helperText: field == 'price' ? '仅影响本次入库；留空为缺价' : '大于0，最多4位小数',
          helperMaxLines: 2,
          errorText: fieldErrors['$key-$field'],
          errorMaxLines: 3,
        ),
        onChanged: (v) => change(() {
          line[field] = v;
          fieldErrors.remove('$key-$field');
        }),
      ),
    );
    final qty = materialScaled(materialText(line, 'quantity'));
    final before = materialScaled(
      materialText(line, kind == 'return' ? 'remaining' : 'available'),
    );
    final targetBefore = materialScaled(materialText(line, 'target_available'));
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
          if (kind != 'inbound')
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                kind == 'return'
                    ? '原出库 ${line['original_quantity']} · 已退 ${line['returned']} · 最多可退 ${line['remaining']} ${line['unit']}'
                    : '可用库存 ${line['available'] ?? '待刷新'} ${line['unit']} · ${qty != null && before != null ? '本次后预计剩余 ${materialUnscaled(before - qty)}' : '填写数量查看预计剩余'}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xff41647f),
                ),
              ),
            ),
          if (targetBefore != null && qty != null)
            Text(
              '目标分类现有 ${materialUnscaled(targetBefore)} → 本次后 ${materialUnscaled(targetBefore + qty)} ${line['unit']}',
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
    if (draft.pending == null && !validate()) return;
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
          if (!mounted || !await confirmDetails()) {
            return;
          }
        } else if (document) {
          if (!mounted || !await confirmDetails()) {
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
          maxWidth: document ? 920 : 640,
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
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          guide,
                          style: const TextStyle(color: Color(0xff41647f)),
                        ),
                      ),
                      if (fieldErrors.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          color: const Color(0xfffff3eb),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '请完善以下内容，点击可定位到对应输入：',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              for (final e in fieldErrors.entries)
                                TextButton(
                                  onPressed: () => focusError(e.key),
                                  child: Text(e.value),
                                ),
                            ],
                          ),
                        ),
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
                        sectionTitle(
                          '1. 物料明细',
                          '选择物料后填写数量，核对分类与单位。库存以最终确认时为准。',
                        ),
                        if (draft.lines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              '还没有添加物料。点击“添加物料”开始；找不到物料时，入库经办人可联系有品类管理权限的人建档。',
                            ),
                          ),
                        for (final line in draft.lines) lineEditor(line),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              key: anchor('lines'),
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
                        sectionTitle('2. 用途与领用信息', '选择常用用途或填写具体说明，领用方为选填。'),
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
                        field('recipient', '领用方（选填）'),
                      ],
                      if (document)
                        field('notes', '备注（选填）', max: 2000, lines: 2),
                      if (kind == 'inbound') ...[
                        sectionTitle(
                          '2. 入库凭证',
                          '选填清单或实物照片，每单最多10张；上传失败时可重试或移除。',
                        ),
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
                          ? '下一步：核对出库'
                          : document
                          ? '下一步：核对$title'
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
