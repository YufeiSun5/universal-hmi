import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'session.dart';
import 'form_guidance.dart';
import 'widgets.dart';

const materialInboundFields = {
  'supplier': '供应商／供货单位',
  'invoice_number': '发票号',
  'contract_number': '合同号',
  'certificate_count': '质量证明书份数',
  'freight': '运杂费',
  'purchaser': '采购员',
  'supervisor': '主管',
  'storekeeper': '保管员',
};
const materialOutboundFields = {
  'project': '工程项目名称',
  'project_number': '工程编号',
  'station': '站所',
  'nature': '性质',
  'recipient_person': '实际领用人',
  'supply_reviewer': '供应审核',
  'supervisor': '主管',
  'storekeeper': '保管员',
};
const materialPersonFields = {
  'purchaser',
  'supervisor',
  'storekeeper',
  'recipient_person',
  'supply_reviewer',
};

Json materialDocumentFields(Json record) =>
    Map<String, dynamic>.from(record['details'] as Map? ?? {});

String materialFieldValue(Json fields, String key) =>
    materialPersonFields.contains(key)
    ? materialText(Map<String, dynamic>.from(fields[key] as Map? ?? {}), 'name')
    : materialText(fields, key);

Map<String, String> materialDocumentFieldErrors(Json fields) {
  final errors = <String, String>{};
  final count = materialText(fields, 'certificate_count').trim();
  if (count.isNotEmpty && (!RegExp(r'^\d{1,9}$').hasMatch(count))) {
    errors['certificate_count'] = '质量证明书份数须为0至999999999的整数';
  }
  final freight = materialNumberError(
    materialText(fields, 'freight').trim(),
    optional: true,
  );
  if (freight != null) errors['freight'] = '运杂费：$freight';
  return errors;
}

Json materialDocumentFieldsPayload(Json fields) => {
  ...fields,
  if (materialText(fields, 'certificate_count').trim().isNotEmpty)
    'certificate_count': int.parse(
      materialText(fields, 'certificate_count').trim(),
    )
  else
    'certificate_count': null,
};

class MaterialDocumentFieldsView extends StatelessWidget {
  const MaterialDocumentFieldsView({super.key, required this.record});
  final Json record;
  @override
  Widget build(BuildContext context) {
    final fields = materialDocumentFields(record);
    final labels = record['kind'] == 'inbound'
        ? materialInboundFields
        : materialOutboundFields;
    final visible = labels.entries
        .where((e) => materialFieldValue(fields, e.key).isNotEmpty)
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final e in visible)
                SelectableText(
                  '${e.value}：${materialFieldValue(fields, e.key)}${e.key == 'freight' ? '（单独记录，不计材料合计）' : ''}',
                ),
            ],
          ),
          if (visible.any((e) => materialPersonFields.contains(e.key)))
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '人员归属不代表已签署，实际签名另列。',
                style: TextStyle(color: Color(0xff647581), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class MaterialDocumentFieldsEditor extends StatefulWidget {
  const MaterialDocumentFieldsEditor({
    super.key,
    required this.api,
    required this.kind,
    required this.values,
    required this.onChanged,
    this.enabled = true,
    this.errors = const {},
  });
  final PlatformApi api;
  final String kind;
  final Json values;
  final ValueChanged<Json> onChanged;
  final bool enabled;
  final Map<String, String> errors;
  @override
  State<MaterialDocumentFieldsEditor> createState() =>
      _MaterialDocumentFieldsEditorState();
}

class _MaterialDocumentFieldsEditorState
    extends State<MaterialDocumentFieldsEditor> {
  final controllers = <String, TextEditingController>{};
  String? error;
  bool loading = false;
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController controller(String key) => controllers.putIfAbsent(
    key,
    () => TextEditingController(text: materialFieldValue(widget.values, key)),
  );
  void update(String key, dynamic value) =>
      widget.onChanged({...widget.values, key: value});

  Future<void> choose(String key) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final station = key == 'station';
      final data = await widget.api.request(
        'GET',
        station ? '/api/v1/stations' : '$materialsBase/personnel',
      );
      if (!mounted) return;
      setState(() => loading = false);
      final result = await showDialog<Json>(
        context: context,
        builder: (_) => _DirectoryPicker(
          title: station ? '选择已有站所' : '选择系统账号',
          items: objects(data['items']),
        ),
      );
      if (!mounted || result == null) return;
      final name = materialText(result, 'name');
      controller(key).text = name;
      update(
        key,
        station ? name : {'user_id': result['user_id'], 'name': name},
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.kind == 'inbound'
        ? materialInboundFields
        : materialOutboundFields;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Text(
          widget.kind == 'inbound' ? '采购与收料信息（选填）' : '工程与领用信息（选填）',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 19),
        ),
        const SizedBox(height: 6),
        Text(
          widget.kind == 'inbound'
              ? '同一张单对应同一供应商、合同；运杂费单独记录。'
              : '同一张单对应同一工程、站所；不同归属请分单。',
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '人员可选系统账号或手填外部姓名；填写人员不代表本人已签署。',
            style: TextStyle(color: Color(0xff647581)),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) materialError(error!),
        LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth >= 650
                ? (box.maxWidth - 16) / 2
                : box.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                for (final e in labels.entries)
                  SizedBox(
                    width: width,
                    child: TextField(
                      key: ValueKey('material-detail-field-${e.key}'),
                      controller: controller(e.key),
                      enabled: widget.enabled && !loading,
                      maxLength: e.key == 'certificate_count' ? 9 : 200,
                      decoration: InputDecoration(
                        labelText: '${e.value}（选填）',
                        counterText: '',
                        errorText: widget.errors[e.key],
                        helperText: e.key == 'freight'
                            ? '不分摊单价，不计材料合计'
                            : e.key == 'certificate_count'
                            ? '非负整数，留空表示未记录'
                            : materialPersonFields.contains(e.key)
                            ? ((widget.values[e.key] as Map?)?['user_id']
                                          ?.toString()
                                          .isNotEmpty ==
                                      true
                                  ? '已选择系统账号；修改姓名将改为手填'
                                  : '手填姓名，或点右侧选择账号')
                            : null,
                        helperMaxLines: 2,
                        errorMaxLines: 2,
                        suffixIcon:
                            materialPersonFields.contains(e.key) ||
                                e.key == 'station'
                            ? IconButton(
                                tooltip: e.key == 'station'
                                    ? '选择已有站所'
                                    : '选择${e.value}账号',
                                onPressed: widget.enabled && !loading
                                    ? () => choose(e.key)
                                    : null,
                                icon: Icon(
                                  e.key == 'station'
                                      ? Icons.location_on_outlined
                                      : Icons.person_search_outlined,
                                ),
                              )
                            : null,
                      ),
                      onChanged: (value) => update(
                        e.key,
                        materialPersonFields.contains(e.key)
                            ? {'user_id': '', 'name': value}
                            : value,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({required this.title, required this.items});
  final String title;
  final List<Json> items;
  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final items = widget.items
        .where(
          (v) => materialText(
            v,
            'name',
          ).toLowerCase().contains(search.toLowerCase()),
        )
        .toList();
    return MaterialWorkflowAlert(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: '搜索名称'),
              onChanged: (v) => setState(() => search = v),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配项，可返回手填'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(materialText(items[i], 'name')),
                        onTap: () => Navigator.pop(context, items[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回'),
        ),
      ],
    );
  }
}
