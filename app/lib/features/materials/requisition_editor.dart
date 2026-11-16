import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../platform/material_files.dart';
import 'session.dart';
import 'widgets.dart';
import 'form_guidance.dart';

String requisitionValue(Object? value) => value == null
    ? ''
    : value is String
    ? value
    : jsonEncode(value);

class RequisitionEditor extends StatefulWidget {
  const RequisitionEditor({
    super.key,
    required this.api,
    required this.session,
    this.seed = const {},
    this.draftKey,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json seed;
  final String? draftKey;
  @override
  State<RequisitionEditor> createState() => _RequisitionEditorState();
}

class _RequisitionEditorState extends State<RequisitionEditor> {
  late final keyName =
      widget.draftKey ?? 'application-${widget.seed['id'] ?? 'new'}';
  late final draft = widget.session.draft(keyName);
  final controllers = <String, TextEditingController>{};
  final tableScroll = ScrollController();
  bool busy = false;
  String? error;
  List<String> warnings = [];
  bool get locked => busy || draft.pending != null;
  List<Json> get lines =>
      (draft.values['requisition_lines'] as List? ?? const <Json>[])
          .cast<Json>();
  List<Json> get attachments =>
      (draft.values['attachments'] as List? ?? const <Json>[]).cast<Json>();
  @override
  void initState() {
    super.initState();
    if (draft.values.isEmpty) {
      final source = widget.seed['requisition'] as Json? ?? {};
      draft.values = {
        'id': widget.seed['id'] ?? '',
        'version': widget.seed['version'] ?? 0,
        'text': widget.seed['text'] ?? '',
        for (final key in [
          'project',
          'project_number',
          'requested_at',
          'contractor',
        ])
          key: source[key] ?? '',
        'requisition_lines': objects(source['lines'])
            .map((l) => <String, dynamic>{...l, 'key': materialOperationID()})
            .toList(),
        'attachments': objects(
          source['attachments'],
        ).map((v) => <String, dynamic>{...v}).toList(),
      };
    }
    draft.values.putIfAbsent('requisition_lines', () => <Json>[]);
    draft.values.putIfAbsent('attachments', () => <Json>[]);
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    tableScroll.dispose();
    super.dispose();
  }

  TextEditingController controller(String key, Object? value) =>
      controllers.putIfAbsent(
        key,
        () => TextEditingController(text: requisitionValue(value)),
      );
  Widget field(
    String key,
    String label, {
    int maxLines = 1,
    int maxLength = 500,
  }) => TextField(
    key: Key('requisition-$key'),
    controller: controller(key, draft.values[key]),
    enabled: !locked,
    maxLines: maxLines,
    maxLength: maxLength,
    decoration: InputDecoration(
      labelText: label,
      counterText: '',
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    onChanged: (v) => draft.set(key, v),
  );
  Future<bool> confirmReplace() async {
    if (lines.isEmpty &&
        [
          'project',
          'project_number',
          'requested_at',
          'contractor',
        ].every((k) => materialText(draft.values, k).isEmpty)) {
      return true;
    }
    return await showDialog<bool>(
          context: context,
          builder: (c) => MaterialWorkflowAlert(
            title: const Text('导入新的清单'),
            content: const Text('将替换当前工程信息和物资明细，保留申请说明及已有附件。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('替换并复核'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> upload() async {
    try {
      if (attachments.length >= 10) throw const FormatException('每单最多10个附件');
      final file = await pickRequisitionFile(excelOnly: true);
      if (file == null || !mounted) return;
      if (!await confirmReplace()) return;
      if (!mounted) return;
      setState(() {
        busy = true;
        error = null;
      });
      final body = <String, dynamic>{
        'operation_id': materialOperationID(),
        'name': file.name,
        'kind': 'attachment',
        'data': base64Encode(file.bytes),
      };
      var result = await widget.api.request(
        'POST',
        '$materialsBase/applications/import',
        body: body,
      );
      if (!mounted) return;
      if (result['asset'] == null) {
        final sheets = (result['sheets'] as List? ?? []).cast<String>();
        final chosen = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('选择要导入的工作表'),
            children: [
              for (final s in sheets)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, s),
                  child: Text(s),
                ),
            ],
          ),
        );
        if (chosen == null) return;
        result = await widget.api.request(
          'POST',
          '$materialsBase/applications/import',
          body: {...body, 'sheet': chosen},
        );
        if (!mounted) return;
      }
      setState(() {
        final parsed = result['requisition'] as Json;
        for (final key in [
          'project',
          'project_number',
          'requested_at',
          'contractor',
        ]) {
          draft.values[key] = parsed[key] ?? '';
          controller(key, '').text = materialText(parsed, key);
        }
        for (final key
            in controllers.keys.where((k) => k.startsWith('line-')).toList()) {
          controllers.remove(key)?.dispose();
        }
        draft.values['requisition_lines'] = objects(parsed['lines'])
            .map((l) => <String, dynamic>{...l, 'key': materialOperationID()})
            .toList();
        warnings = (result['warnings'] as List? ?? [])
            .map((v) => '$v')
            .toList();
        attachments.add(result['asset'] as Json);
        draft.changed();
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Json payload() => {
    'workflow': 2,
    'id': draft.values['id'],
    'version': draft.values['version'],
    'text': draft.values['text'],
    'requisition': {
      for (final k in [
        'project',
        'project_number',
        'requested_at',
        'contractor',
      ])
        k: draft.values[k],
      'lines': lines
          .where(
            (l) => [
              'name',
              'specification',
              'unit',
              'quantity',
              'needed_at',
              'notes',
            ].any((k) => requisitionValue(l[k]).trim().isNotEmpty),
          )
          .map(
            (l) => {
              for (final k in [
                'name',
                'specification',
                'unit',
                'quantity',
                'needed_at',
                'notes',
              ])
                k: l[k] ?? '',
            },
          )
          .toList(),
      'asset_ids': attachments.map((a) => a['id']).toList(),
    },
  };
  Future<void> submit() async {
    if (draft.pending == null) {
      final input = payload();
      final items = objects((input['requisition'] as Json)['lines']);
      String? problem;
      if (items.isEmpty && materialText(input, 'text').trim().isEmpty) {
        problem = '请填写申请说明或添加物资明细';
      }
      for (var i = 0; i < items.length; i++) {
        final l = items[i];
        if (materialText(l, 'name').trim().isEmpty ||
            materialText(l, 'unit').trim().isEmpty) {
          problem = '第 ${i + 1} 行：请填写器材名称和单位';
          break;
        }
        final e = materialNumberError(
          materialText(l, 'quantity'),
          positive: true,
        );
        if (e != null) {
          problem = '第 ${i + 1} 行数量：$e';
          break;
        }
      }
      if (problem != null) {
        setState(() => error = problem);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => MaterialWorkflowAlert(
          title: const Text('确认复核并提交'),
          content: Text(
            '工程：${materialText(draft.values, 'project').isEmpty ? '未填写' : draft.values['project']}\n有效明细 ${items.length} 条，附件 ${attachments.length} 个。\n\n确认后记录您为编制人并附上本人签名，提交给审核人员。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续检查'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认并签名提交'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await draft.submit(
        widget.api,
        '$materialsBase/applications',
        payload(),
      );
      widget.session.clear(keyName);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> close() async {
    if (busy) return;
    if (draft.dirty || draft.pending != null) {
      final keep = await showDialog<bool>(
        context: context,
        builder: (c) => MaterialWorkflowAlert(
          title: const Text('保留申请草稿'),
          content: Text(
            draft.pending != null
                ? '提交结果尚未确认。保留原操作，重新打开后可重试确认。'
                : '当前内容尚未提交，保留后可以继续编辑。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保留并返回'),
            ),
          ],
        ),
      );
      if (keep != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Widget lineField(Json line, String key, double width) => SizedBox(
    width: width,
    child: TextField(
      key: Key('requisition-line-${line['key']}-$key'),
      controller: controller('line-${line['key']}-$key', line[key]),
      enabled: !locked,
      minLines: 1,
      maxLines: 3,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      onChanged: (v) {
        line[key] = v;
        draft.changed();
      },
    ),
  );
  Widget table() => Scrollbar(
    controller: tableScroll,
    thumbVisibility: true,
    child: SingleChildScrollView(
      controller: tableScroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 14),
      child: DataTable(
        headingRowColor: const WidgetStatePropertyAll(Color(0xffe8eff5)),
        columnSpacing: 12,
        horizontalMargin: 8,
        dataRowMinHeight: 58,
        dataRowMaxHeight: 96,
        columns: [
          for (final name in [
            '序号',
            '器材名称',
            '型号与规格',
            '单位',
            '数量',
            '需求时间',
            '备注',
            '',
          ])
            DataColumn(label: Text(name)),
        ],
        rows: [
          for (var i = 0; i < lines.length; i++)
            DataRow(
              key: ValueKey(lines[i]['key']),
              cells: [
                DataCell(Text('${i + 1}')),
                for (final item in <(String, double)>[
                  ('name', 160),
                  ('specification', 130),
                  ('unit', 60),
                  ('quantity', 85),
                  ('needed_at', 130),
                  ('notes', 180),
                ])
                  DataCell(lineField(lines[i], item.$1, item.$2)),
                DataCell(
                  IconButton(
                    tooltip: '移除此行',
                    onPressed: locked
                        ? null
                        : () {
                            setState(() => lines.removeAt(i));
                            draft.changed();
                          },
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !draft.dirty && draft.pending == null,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) close();
    },
    child: MaterialWorkflowDialog(
      child: SizedBox(
        width: 1120,
        height: MediaQuery.sizeOf(context).height * .88,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '编制请购申请',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '保留草稿并返回',
                    onPressed: busy ? null : close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '填写申请或导入 Excel，检查工程信息与明细后签名提交。需求时间支持自由填写。',
                style: TextStyle(color: Color(0xff647581)),
              ),
              const Divider(height: 24),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: locked ? null : upload,
                            icon: const Icon(Icons.table_view_outlined),
                            label: const Text('导入 Excel 并复核'),
                          ),
                        ],
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: materialError(error!),
                        ),
                      if (draft.pending != null)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('提交结果待确认。内容已锁定，请重试确认提交，避免重复申请。'),
                        ),
                      for (final warning in warnings)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            warning,
                            style: const TextStyle(color: Color(0xff926100)),
                          ),
                        ),
                      const SizedBox(height: 18),
                      LayoutBuilder(
                        builder: (c, b) {
                          final w = b.maxWidth > 650
                              ? (b.maxWidth - 16) / 2
                              : b.maxWidth;
                          return Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              SizedBox(
                                width: w,
                                child: field('project', '工程项目名称'),
                              ),
                              SizedBox(
                                width: w,
                                child: field('project_number', '工程编号（选填）'),
                              ),
                              SizedBox(
                                width: w,
                                child: field('requested_at', '请购时间（选填）'),
                              ),
                              SizedBox(
                                width: w,
                                child: field('contractor', '施工单位'),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 18),
                      field(
                        'text',
                        '申请说明（可单独填写文字申请）',
                        maxLines: 3,
                        maxLength: 10000,
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '物资明细 · ${lines.length} 条',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: locked || lines.length >= 1000
                                ? null
                                : () {
                                    setState(
                                      () => lines.add({
                                        'key': materialOperationID(),
                                      }),
                                    );
                                    draft.changed();
                                  },
                            icon: const Icon(Icons.add),
                            label: const Text('添加明细'),
                          ),
                        ],
                      ),
                      if (lines.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text('尚无明细。可以导入 Excel、添加明细，或仅填写上方申请说明。'),
                        )
                      else
                        table(),
                      if (attachments.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text(
                          '导入原稿 · 仅供追溯',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        for (final a in attachments)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(materialText(a, 'name')),
                            trailing: IconButton(
                              tooltip: '移除附件',
                              onPressed: locked
                                  ? null
                                  : () {
                                      setState(() => attachments.remove(a));
                                      draft.changed();
                                    },
                              icon: const Icon(Icons.close),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  MaterialAccountLink(
                    session: widget.session,
                    enabled: !locked,
                  ),
                  TextButton(
                    onPressed: busy ? null : close,
                    child: const Text('保留草稿'),
                  ),
                  FilledButton.icon(
                    onPressed: busy ? null : submit,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(draft.pending == null ? '复核并提交' : '重试确认提交'),
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
