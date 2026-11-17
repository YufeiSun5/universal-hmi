import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../platform/save.dart';
import 'session.dart';
import 'widgets.dart';
import 'requisition_editor.dart';

String requisitionStage(String stage) =>
    const {
      'compile': '编制提交',
      'review': '审核',
      'approval': '批准',
      'receipt': '物资已阅',
      'legacy_approval': '原流程审批',
    }[stage] ??
    '未识别办理环节';

List<Json> requisitionSteps(Json version, String owner) {
  if (version['workflow'] == 2) return objects(version['steps']);
  return [
    {
      'id': 'legacy-${version['version']}-submit',
      'stage': 'compile',
      'actor': owner,
      'created': version['submitted'],
      'decision': 'submitted',
      'signature_id': '',
    },
    if (materialText(version, 'decided').isNotEmpty)
      {
        'id': 'legacy-${version['version']}-decision',
        'stage': 'legacy_approval',
        'actor': version['approver'],
        'created': version['decided'],
        'decision': version['status'],
        'signature_id': version['signature_id'],
        'reason': version['reason'],
      },
  ];
}

class RequisitionSnapshot extends StatelessWidget {
  const RequisitionSnapshot({super.key, required this.record});
  final Json record;
  @override
  Widget build(BuildContext context) {
    final r = record['requisition'] as Json? ?? {};
    final lines = objects(r['lines']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final field in <(String, String)>[
                ('project', '工程项目名称'),
                ('project_number', '工程编号'),
                ('requested_at', '请购时间'),
                ('contractor', '施工单位'),
              ])
                SizedBox(
                  width: box.maxWidth >= 760
                      ? (box.maxWidth - 72) / 4
                      : (box.maxWidth - 24) / 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        field.$2,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff647581),
                        ),
                      ),
                      const SizedBox(height: 3),
                      SelectableText(
                        materialText(r, field.$1).isEmpty
                            ? '—'
                            : materialText(r, field.$1),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (materialText(record, 'text').isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            '申请说明',
            style: TextStyle(fontSize: 12, color: Color(0xff647581)),
          ),
          const SizedBox(height: 4),
          SelectableText(materialText(record, 'text')),
        ],
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '物资明细 · ${lines.length} 条',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth),
                child: DataTable(
                  headingRowColor: const WidgetStatePropertyAll(
                    Color(0xffe8eff5),
                  ),
                  horizontalMargin: 12,
                  columnSpacing: 18,
                  headingRowHeight: 36,
                  dataRowMinHeight: 34,
                  dataRowMaxHeight: double.infinity,
                  columns: [
                    for (final name in [
                      '序号',
                      '器材名称',
                      '型号与规格',
                      '单位',
                      '数量',
                      '需求时间',
                      '备注',
                    ])
                      DataColumn(label: Text(name)),
                  ],
                  rows: [
                    for (var i = 0; i < lines.length; i++)
                      DataRow(
                        cells: [
                          DataCell(Text('${i + 1}')),
                          for (final key in [
                            'name',
                            'specification',
                            'unit',
                            'quantity',
                            'needed_at',
                            'notes',
                          ])
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 210,
                                ),
                                child: SelectableText(
                                  requisitionValue(lines[i][key]),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class RequisitionDetail extends StatefulWidget {
  const RequisitionDetail({
    super.key,
    required this.api,
    required this.session,
    required this.record,
    required this.versions,
    required this.access,
    required this.onDecision,
    required this.onEdit,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json record, access;
  final List<Json> versions;
  final Future<void> Function(String) onDecision;
  final Future<void> Function() onEdit;
  @override
  State<RequisitionDetail> createState() => _RequisitionDetailState();
}

class _RequisitionDetailState extends State<RequisitionDetail> {
  bool busy = false;
  String? error, message, expanded;
  Json get record => widget.record;
  bool allowed(String key) =>
      (widget.access['grants'] as Json? ?? {})['materials_$key'] == true;
  Future<void> download({Json? attachment, int? version}) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        attachment != null
            ? '$materialsBase/assets/${attachment['id']}'
            : '$materialsBase/applications/${record['id']}/export',
        query: attachment != null
            ? null
            : {'encoding': 'base64', 'version': ?version},
      );
      final name = attachment != null
          ? materialText(result['asset'] as Json, 'name')
          : materialText(result, 'name');
      final saved = await saveFile(
        base64Decode(materialText(result, 'data')),
        name,
      );
      if (mounted) setState(() => message = saved ? '已交给文件保存功能。' : '已取消保存。');
    } catch (e) {
      if (mounted) setState(() => error = '下载失败，可重试。$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> snapshot(Json version) => showDialog<void>(
    context: context,
    builder: (c) => MaterialWorkflowDialog(
      child: SizedBox(
        width: 1000,
        height: MediaQuery.sizeOf(c).height * .8,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '第 ${version['version']} 版清单',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(c),
                    tooltip: '关闭版本',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RequisitionSnapshot(record: version),
                      const SizedBox(height: 16),
                      for (final step in requisitionSteps(
                        version,
                        materialText(record, 'owner'),
                      ))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${requisitionStage(materialText(step, 'stage'))}：${step['actor']} · ${materialTime(step['created'])}${step['decision'] == 'rejected' ? ' · 已退回' : ''}',
                              ),
                              if (materialText(step, 'reason').isNotEmpty)
                                Text(materialText(step, 'reason')),
                              if (materialText(step, 'signature_id').isNotEmpty)
                                MaterialAssetView(
                                  api: widget.api,
                                  id: materialText(step, 'signature_id'),
                                  height: 58,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: busy || version['status'] != 'closed'
                      ? null
                      : () => download(version: version['version'] as int),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出此版流程 Excel'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget node(
    Json version,
    Json step, {
    required bool first,
    required bool last,
  }) {
    final rejected = step['decision'] == 'rejected';
    final recompiled =
        step['stage'] == 'compile' && (version['version'] as int) > 1;
    final color = rejected
        ? const Color(0xffb54c42)
        : recompiled
        ? const Color(0xff9b7324)
        : const Color(0xff47788c);
    final id = materialText(step, 'id');
    final open = expanded == id;
    final label = recompiled
        ? '修改重提'
        : requisitionStage(materialText(step, 'stage'));
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 38,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: 14,
                  color: first ? Colors.transparent : const Color(0xffbccbd3),
                ),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                  child: Icon(
                    rejected
                        ? Icons.undo
                        : recompiled
                        ? Icons.call_split
                        : Icons.check,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: last ? Colors.transparent : const Color(0xffbccbd3),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: open ? const Color(0xfff0f5f8) : Colors.white,
                  border: Border.all(color: const Color(0xffd3dde4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: () => setState(() => expanded = open ? null : id),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 4,
                                    children: [
                                      Text(
                                        '$label${rejected ? ' · 退回' : ''}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: color,
                                        ),
                                      ),
                                      Text(
                                        '第 ${version['version']} 版',
                                        style: const TextStyle(
                                          color: Color(0xff647581),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '${step['actor']}    ${materialTime(step['created'])}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xff647581),
                                    ),
                                  ),
                                  if (materialText(step, 'reason').isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        '${rejected ? '退回原因' : '备注'}：${step['reason']}',
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Icon(
                              open ? Icons.expand_less : Icons.expand_more,
                              color: const Color(0xff647581),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (open)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (materialText(step, 'signature_id').isNotEmpty)
                              MaterialAssetView(
                                api: widget.api,
                                id: materialText(step, 'signature_id'),
                                height: 62,
                              ),
                            TextButton.icon(
                              onPressed: () => snapshot(version),
                              icon: const Icon(
                                Icons.description_outlined,
                                size: 18,
                              ),
                              label: const Text('查看此版清单与签名'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = materialText(record, 'status');
    final canAct = switch (status) {
      'review' => allowed('review'),
      'approval' => allowed('approve'),
      'receipt' => allowed('receive'),
      _ => false,
    };
    final action = switch (status) {
      'review' => '审核通过',
      'approval' => '批准申请',
      'receipt' => '确认已阅',
      _ => '',
    };
    final entries = <({Json version, Json step})>[
      for (final v in widget.versions)
        for (final step in requisitionSteps(v, materialText(record, 'owner')))
          (version: v, step: step),
    ];
    final attachments = objects(
      (record['requisition'] as Json? ?? {})['attachments'],
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MaterialStatusBadge(status: status, prominent: true),
            Text(
              '${record['number']} · 第 ${record['version']} 版',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text('编制人：${record['owner']}'),
          ],
        ),
        const SizedBox(height: 12),
        RequisitionSnapshot(record: record),
        if (attachments.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final a in attachments)
                TextButton.icon(
                  onPressed: busy ? null : () => download(attachment: a),
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: Text('下载原始附件 · ${materialText(a, 'name')}'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (canAct)
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => widget.onDecision(
                        status == 'receipt' ? 'received' : 'approved',
                      ),
                icon: Icon(
                  status == 'receipt'
                      ? Icons.mark_email_read_outlined
                      : Icons.check_circle_outline,
                ),
                label: Text(action),
              ),
            if (canAct && status != 'receipt')
              OutlinedButton.icon(
                onPressed: busy ? null : () => widget.onDecision('rejected'),
                icon: const Icon(Icons.undo),
                label: const Text('退回编制人'),
              ),
            if (status == 'rejected' &&
                record['owner_id'] == widget.access['user_id'] &&
                allowed('request'))
              FilledButton.icon(
                onPressed: busy ? null : widget.onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('修改并重新提交'),
              ),
            OutlinedButton.icon(
              onPressed: busy || status != 'closed' ? null : () => download(),
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出完整流程 Excel'),
            ),
          ],
        ),
        if (status != 'closed')
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '完成审核、批准和物资已阅后可导出。',
              style: TextStyle(fontSize: 12, color: Color(0xff647581)),
            ),
          ),
        if (status == 'receipt')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '确认已阅表示您已看到清单，确认后申请闭环。',
              style: TextStyle(color: Color(0xff647581)),
            ),
          ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) materialError(error!),
        if (message != null) Text(message!),
      ],
    );
    final history = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '办理链',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          '按办理顺序保留每次签名；点击节点查看对应版本。',
          style: TextStyle(fontSize: 13, color: Color(0xff647581)),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < entries.length; i++)
          node(
            entries[i].version,
            entries[i].step,
            first: i == 0,
            last:
                i == entries.length - 1 &&
                ['closed', 'rejected'].contains(status),
          ),
        if (!['closed', 'rejected'].contains(status))
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 16),
            child: Row(
              children: [
                const Icon(
                  Icons.radio_button_unchecked,
                  color: Color(0xff8b9ba7),
                  size: 22,
                ),
                const SizedBox(width: 18),
                Text(
                  '${materialStatus(status)} · 等待办理',
                  style: const TextStyle(color: Color(0xff647581)),
                ),
              ],
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 1050) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [content, const Divider(height: 24), history],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            const SizedBox(width: 24),
            Container(
              width: 306,
              padding: const EdgeInsets.only(left: 18),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Color(0xffd3dde4))),
              ),
              child: history,
            ),
          ],
        );
      },
    );
  }
}
