import 'package:flutter/material.dart';
import '../../shared/pagination.dart';
import '../../shared/api.dart';
import 'session.dart';
import 'widgets.dart';
import 'editor.dart';
import 'document_export.dart';

Future<void> showMaterialDetail(
  BuildContext context,
  PlatformApi api,
  MaterialsSession session, {
  required String kind,
  required Json record,
  required Json access,
}) => showDialog<void>(
  context: context,
  builder: (_) => MaterialDetail(
    api: api,
    session: session,
    kind: kind,
    record: record,
    access: access,
  ),
);

class MaterialDetail extends StatefulWidget {
  const MaterialDetail({
    super.key,
    required this.api,
    required this.session,
    required this.kind,
    required this.record,
    required this.access,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final String kind;
  final Json record, access;
  @override
  State<MaterialDetail> createState() => _MaterialDetailState();
}

class _MaterialDetailState extends State<MaterialDetail> {
  Json? data;
  Json? stockRecord;
  bool loading = true, busy = false;
  String? error, message;
  int offset = 0;
  Json get grants => widget.access['grants'] as Json? ?? {};
  bool allowed(String key) => grants['materials_$key'] == true;
  bool get application => widget.kind == 'application';
  bool get stock => widget.kind == 'stock';
  Json get record =>
      data?[application ? 'application' : 'document'] as Json? ?? widget.record;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        stock
            ? '$materialsBase/movements'
            : application
            ? '$materialsBase/applications/${widget.record['id']}'
            : '$materialsBase/documents/${widget.record['id']}',
        query: {
          'offset': offset,
          'limit': 50,
          if (stock) 'item_id': widget.record['id'],
        },
      );
      if (stock) {
        final balances = await widget.api.request(
          'GET',
          '$materialsBase/stock',
          query: {
            'item_id': widget.record['id'],
            'category_id': widget.record['stock_category_id'],
          },
        );
        final items = objects(balances['items']);
        stockRecord = items.isEmpty ? null : items.first;
      }
      if (mounted) setState(() => data = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> export() async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final result = await exportMaterialDocument(widget.api, record);
      if (mounted) {
        setState(() => message = result);
      }
    } catch (e) {
      if (mounted) setState(() => error = '导出失败，可重试；不会再次扣库存。$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> decision(String decision) async {
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DecisionDialog(
        api: widget.api,
        session: widget.session,
        record: record,
        decision: decision,
      ),
    );
    if (done == true && mounted) load();
  }

  Widget lineCard(Json line) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffd3dbe3)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${line['name']} · ${line['specification'] ?? ''}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          '分类：${line['category'] ?? ''}${materialText(line, 'target_category').isEmpty ? '' : ' → ${line['target_category']}'}',
        ),
        Text('数量：${line['quantity']} ${line['unit']}'),
        if (!stock && materialText(record, 'kind') != 'transfer')
          Text(
            '单价：${materialText(line, 'price').isEmpty ? '未填' : line['price']}　金额：${materialText(line, 'amount').isEmpty ? '—' : line['amount']}',
          ),
        if (record['kind'] == 'outbound')
          Text(
            '累计已退 ${line['returned']}，剩余可退 ${line['remaining']} ${line['unit']}',
          ),
      ],
    ),
  );
  Widget linkedDocument(Json doc, {bool summary = false}) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text('${materialKind(materialText(doc, 'kind'))}单 ${doc['number']}'),
    subtitle: Text(
      '${materialTime(doc['created'])} · ${doc['owner'] ?? ''}\n${objects(doc['lines']).map((l) => '${l['name']} ${l['quantity']} ${l['unit']}').join('；')}',
    ),
    trailing: summary ? const Text('仅摘要') : const Icon(Icons.chevron_right),
    onTap: summary
        ? null
        : () => showMaterialDetail(
            context,
            widget.api,
            widget.session,
            kind: 'document',
            record: doc,
            access: widget.access,
          ),
  );
  Widget movements(List<Json> records) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final m in records)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${materialKind(materialText(m, 'kind'))} ${m['quantity']} · ${m['number']}',
          ),
          subtitle: Text('${materialTime(m['created'])} · ${m['actor']}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showMaterialDetail(
            context,
            widget.api,
            widget.session,
            kind: 'document',
            record: {'id': m['document_id']},
            access: widget.access,
          ),
        ),
    ],
  );
  Widget heading(String title) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  );
  Widget applicationBody() {
    final versions = objects(data?['versions']);
    final inbound = data?['inbound'] as Json? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${record['number']} · ${record['owner']}'),
            MaterialStatusBadge(status: materialText(record, 'status')),
          ],
        ),
        const SizedBox(height: 12),
        SelectableText(materialText(record, 'text')),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (record['status'] == 'pending' &&
                record['owner_id'] != widget.access['user_id'] &&
                allowed('approve')) ...[
              FilledButton(
                onPressed: busy ? null : () => decision('approved'),
                child: const Text('通过申请'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => decision('rejected'),
                child: const Text('驳回申请'),
              ),
            ],
            if (record['status'] == 'rejected' &&
                record['owner_id'] == widget.access['user_id'] &&
                allowed('request'))
              OutlinedButton(
                onPressed: () async {
                  await editMaterial(
                    context,
                    widget.api,
                    widget.session,
                    kind: 'application',
                    seed: record,
                  );
                  if (mounted) load();
                },
                child: const Text('修改并重新提交'),
              ),
            if (record['status'] == 'approved' && allowed('inbound'))
              OutlinedButton(
                onPressed: () async {
                  await editMaterial(
                    context,
                    widget.api,
                    widget.session,
                    kind: 'inbound',
                    canCatalog: allowed('catalog'),
                    seed: {
                      'application_id': record['id'],
                      'application_version': record['version'],
                      'application_label':
                          '${record['number']} · ${record['text']}',
                    },
                    draftKey: 'inbound-${record['id']}',
                  );
                  if (mounted) load();
                },
                child: const Text('关联入库'),
              ),
          ],
        ),
        heading('提交与审批历史'),
        for (final v in versions)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('第 ${v['version']} 版'),
                MaterialStatusBadge(status: materialText(v, 'status')),
              ],
            ),
            subtitle: Text(materialTime(v['submitted'])),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(materialText(v, 'text')),
              ),
              if (materialText(v, 'approver').isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '审批：${v['approver']} · ${materialTime(v['decided'])}',
                  ),
                ),
              if (materialText(v, 'reason').isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('原因：${v['reason']}'),
                ),
              if (materialText(v, 'signature_id').isNotEmpty)
                MaterialAssetView(
                  api: widget.api,
                  id: materialText(v, 'signature_id'),
                  height: 80,
                ),
            ],
          ),
        heading('关联入库追溯'),
        Text(
          (inbound['total'] ?? 0) == 0
              ? '尚无入库记录'
              : '已关联入库，共 ${inbound['total']} 批',
        ),
        for (final total in objects(data?['totals']))
          Text('${total['name']}：${total['quantity']} ${total['unit']}'),
        for (final doc in objects(inbound['items']))
          linkedDocument(doc, summary: !allowed('inbound')),
        pagination(inbound['total'] as int? ?? 0),
      ],
    );
  }

  Widget documentBody() {
    final kind = materialText(record, 'kind');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${record['number']} · ${materialStatus(materialText(record, 'status'))}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text('经办人：${record['owner']}　时间：${materialTime(record['created'])}'),
        if (materialText(record, 'purpose').isNotEmpty)
          Text('用途：${record['purpose']}'),
        if (materialText(record, 'recipient').isNotEmpty)
          Text('领用方：${record['recipient']}'),
        if (materialText(record, 'notes').isNotEmpty)
          Text('备注：${record['notes']}'),
        if (kind == 'inbound') ...[
          if (materialText(record, 'application_id').isEmpty)
            const Text('来源：独立入库')
          else
            TextButton(
              onPressed: data?['can_read_application'] == true
                  ? () => showMaterialDetail(
                      context,
                      widget.api,
                      widget.session,
                      kind: 'application',
                      record: {'id': record['application_id']},
                      access: widget.access,
                    )
                  : null,
              child: Text('查看来源申请 · 批准版本 ${record['application_version']}'),
            ),
        ],
        if (kind == 'return')
          TextButton(
            onPressed: () => showMaterialDetail(
              context,
              widget.api,
              widget.session,
              kind: 'document',
              record: {'id': record['source_id']},
              access: widget.access,
            ),
            child: const Text('返回原出库单'),
          ),
        heading('物料明细'),
        for (final line in objects(record['lines'])) lineCard(line),
        if (materialText(record, 'known_amount').isNotEmpty)
          Text(
            '${record['missing_prices'] == 0 ? '合计金额' : '已知金额小计'}：${record['known_amount']}${record['missing_prices'] == 0 ? '' : '；缺价 ${record['missing_prices']} 行'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        if (materialText(record, 'signature_id').isNotEmpty) ...[
          heading('经办人签名'),
          MaterialAssetView(
            api: widget.api,
            id: materialText(record, 'signature_id'),
          ),
        ],
        if ((record['asset_ids'] as List? ?? []).isNotEmpty) ...[
          heading('入库凭证'),
          for (final id in record['asset_ids'] as List)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: MaterialAssetView(api: widget.api, id: '$id', height: 180),
            ),
        ],
        if (kind == 'inbound' && (record['asset_ids'] as List? ?? []).isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('未附入库凭证'),
          ),
        if (kind == 'outbound') ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : export,
                icon: const Icon(Icons.download),
                label: const Text('导出Excel出库单'),
              ),
              if (record['owner_id'] == widget.access['user_id'] &&
                  allowed('outbound') &&
                  record['status'] != 'returned')
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          await editMaterial(
                            context,
                            widget.api,
                            widget.session,
                            kind: 'return',
                            seed: record,
                          );
                          if (mounted) load();
                        },
                  child: const Text('办理退库'),
                ),
            ],
          ),
          heading('退库追溯'),
          if ((data?['returns']?['total'] ?? 0) == 0) const Text('暂无退库记录'),
          for (final d in objects(data?['returns']?['items']))
            linkedDocument(d),
        ],
        heading('库存流水'),
        movements(objects(data?['movements']?['items'])),
        pagination(
          ((data?['returns']?['total'] as int? ?? 0) >
                  (data?['movements']?['total'] as int? ?? 0))
              ? (data!['returns']['total'] as int)
              : (data?['movements']?['total'] as int? ?? 0),
        ),
      ],
    );
  }

  Widget stockBody() {
    final current = stockRecord ?? widget.record;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${current['name']} · ${current['specification']}'),
        Text(
          '分类：${current['stock_category']} · 该类库存 ${current['quantity']} ${current['unit']}',
        ),
        Text(
          '各类合计 ${current['total_quantity']} · 预警值 ${current['warning']}${current['low'] == true ? ' · 低库存' : ''}',
          style: TextStyle(
            color: current['low'] == true
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        ),
        if (allowed('catalog'))
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () async {
                await editMaterial(
                  context,
                  widget.api,
                  widget.session,
                  kind: 'transfer',
                  seed: current,
                );
                if (mounted) load();
              },
              child: const Text('转移部分库存'),
            ),
          ),
        heading('有权查看的库存流水'),
        if (objects(data?['items']).isEmpty) const Text('暂无有权查看的流水'),
        movements(objects(data?['items'])),
        pagination(data?['total'] as int? ?? 0),
      ],
    );
  }

  Widget pagination(int total) => total <= 50
      ? const SizedBox.shrink()
      : PaginationBar(
          total: total,
          offset: offset,
          pageSize: 50,
          busy: loading,
          onChanged: (v) {
            offset = v;
            load();
          },
        );
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: SizedBox(
      width: 820,
      height: MediaQuery.sizeOf(context).height * .9,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    stock
                        ? '物料库存与流水'
                        : application
                        ? '申请详情与追溯'
                        : '单据详情与追溯',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '刷新详情',
                  onPressed: loading ? null : load,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '返回列表',
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (loading || busy) const LinearProgressIndicator(),
            if (error != null) materialError(error!, retry: load),
            if (message != null) Text(message!),
            Expanded(
              child: data == null
                  ? const SizedBox.shrink()
                  : SingleChildScrollView(
                      child: stock
                          ? stockBody()
                          : application
                          ? applicationBody()
                          : documentBody(),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({
    required this.api,
    required this.session,
    required this.record,
    required this.decision,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json record;
  final String decision;
  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  late final keyName = 'decision-${widget.record['id']}-${widget.decision}';
  late final draft = widget.session.draft(keyName);
  late final reason = TextEditingController(
    text: materialText(draft.values, 'reason'),
  );
  bool busy = false;
  String? error;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await draft.submit(
        widget.api,
        '$materialsBase/applications/${widget.record['id']}/decision',
        {
          'version': widget.record['version'],
          'decision': widget.decision,
          'reason': reason.text,
        },
      );
      widget.session.clear(keyName);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.decision == 'approved' ? '通过申请' : '驳回申请'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.record['number']} · 第 ${widget.record['version']} 版',
            ),
            const SizedBox(height: 12),
            Text(materialText(widget.record, 'text')),
            const SizedBox(height: 16),
            if (widget.decision == 'approved') const Text('通过后附上您当前已保存的签名。'),
            TextField(
              key: const Key('material-decision-reason'),
              controller: reason,
              enabled: !busy && draft.pending == null,
              maxLines: 3,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: widget.decision == 'rejected'
                    ? '驳回原因（必填）'
                    : '审批备注（选填）',
              ),
              onChanged: (v) => draft.set('reason', v),
            ),
            if (error != null) materialError(error!),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      MaterialAccountLink(
        session: widget.session,
        enabled: !busy && draft.pending == null,
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('返回'),
      ),
      FilledButton(
        onPressed: busy ? null : submit,
        child: Text(draft.pending == null ? '确认' : '重试确认'),
      ),
    ],
  );
}
