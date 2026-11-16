import 'package:flutter/material.dart';
import '../../shared/pagination.dart';
import '../../shared/api.dart';
import 'session.dart';
import 'widgets.dart';
import 'editor.dart';
import 'document_export.dart';
import 'requisition_detail.dart';

ButtonStyle _detailActionStyle(BuildContext context, {bool reject = false}) =>
    FilledButton.styleFrom(
      minimumSize: const Size(136, 44),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      visualDensity: VisualDensity.standard,
      foregroundColor: reject ? Theme.of(context).colorScheme.error : null,
      side: reject
          ? BorderSide(color: Theme.of(context).colorScheme.error)
          : null,
    );

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
  int loadGeneration = 0;
  final detailScroll = ScrollController();
  bool resetScroll = true;
  late String selectedKind = widget.kind;
  late Json selectedRecord = widget.record;
  final trail = <({String kind, Json record, int offset})>[];
  Json get grants => widget.access['grants'] as Json? ?? {};
  bool allowed(String key) => grants['materials_$key'] == true;
  bool get application => selectedKind == 'application';
  bool get stock => selectedKind == 'stock';
  Json get record =>
      data?[application ? 'application' : 'document'] as Json? ??
      selectedRecord;

  void openRelated(String kind, Json next) {
    if (kind == selectedKind && next['id'] == selectedRecord['id']) return;
    final previous = trail.indexWhere(
      (v) => v.kind == kind && v.record['id'] == next['id'],
    );
    setState(() {
      if (previous >= 0) {
        trail.removeRange(previous, trail.length);
      } else {
        trail.add((kind: selectedKind, record: selectedRecord, offset: offset));
      }
      selectedKind = kind;
      selectedRecord = next;
      offset = 0;
      data = null;
      stockRecord = null;
      message = null;
      resetScroll = true;
    });
    load();
  }

  void backToRelated() {
    final previous = trail.removeLast();
    setState(() {
      selectedKind = previous.kind;
      selectedRecord = previous.record;
      offset = previous.offset;
      data = null;
      stockRecord = null;
      message = null;
      resetScroll = true;
    });
    load();
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    detailScroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++loadGeneration;
    final isStock = stock, isApplication = application;
    final source = selectedRecord;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        isStock
            ? '$materialsBase/movements'
            : isApplication
            ? '$materialsBase/applications/${source['id']}'
            : '$materialsBase/documents/${source['id']}',
        query: {
          'offset': offset,
          'limit': 50,
          if (isStock) 'item_id': source['id'],
        },
      );
      Json? nextStock;
      if (isStock) {
        final balances = await widget.api.request(
          'GET',
          '$materialsBase/stock',
          query: {
            'item_id': source['id'],
            'category_id': source['stock_category_id'],
          },
        );
        final items = objects(balances['items']);
        nextStock = items.isEmpty ? null : items.first;
      }
      if (mounted && token == loadGeneration) {
        setState(() {
          data = result;
          stockRecord = nextStock;
        });
        if (resetScroll) {
          resetScroll = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && token == loadGeneration && detailScroll.hasClients) {
              detailScroll.jumpTo(0);
            }
          });
        }
      }
    } catch (e) {
      if (mounted && token == loadGeneration) setState(() => error = '$e');
    }
    if (mounted && token == loadGeneration) setState(() => loading = false);
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
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: const Color(0xffd3dbe3)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${line['name']}${materialText(line, 'specification').isEmpty ? '' : ' · ${line['specification']}'}',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          '分类：${line['category'] ?? ''}${materialText(line, 'target_category').isEmpty ? '' : ' → ${line['target_category']}'}',
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 32,
          runSpacing: 10,
          children: [
            detailValue('数量', '${line['quantity']} ${line['unit']}'),
            if (!stock && materialText(record, 'kind') != 'transfer')
              detailValue(
                '金额',
                materialText(line, 'amount').isEmpty
                    ? '未计价'
                    : '¥${line['amount']}',
              ),
            if (record['kind'] == 'outbound')
              detailValue('剩余可退', '${line['remaining']} ${line['unit']}'),
          ],
        ),
        if (!stock && materialText(record, 'kind') != 'transfer') ...[
          const SizedBox(height: 8),
          Text(
            '单价：${materialText(line, 'price').isEmpty ? '未填' : '¥${line['price']}'}',
          ),
        ],
        if (record['kind'] == 'outbound')
          Text('累计已退：${line['returned']} ${line['unit']}'),
      ],
    ),
  );
  Widget detailValue(String label, String value, {double size = 22}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 3),
      Text(
        value,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget linkedDocument(Json doc, {bool summary = false}) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text('${materialKind(materialText(doc, 'kind'))}单 ${doc['number']}'),
    subtitle: Text(
      '${materialTime(doc['created'])} · ${doc['owner'] ?? ''}\n${objects(doc['lines']).map((l) => '${l['name']} ${l['quantity']} ${l['unit']}').join('；')}',
    ),
    trailing: summary ? const Text('仅摘要') : const Icon(Icons.chevron_right),
    onTap: summary ? null : () => openRelated('document', doc),
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
          trailing: !stock && !application && m['document_id'] == record['id']
              ? const Text('本单流水')
              : const Icon(Icons.chevron_right),
          onTap: !stock && !application && m['document_id'] == record['id']
              ? null
              : () => openRelated('document', {'id': m['document_id']}),
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
    if (record['workflow'] == 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RequisitionDetail(
            key: ValueKey('${record['id']}-${record['version']}'),
            api: widget.api,
            session: widget.session,
            record: record,
            versions: versions,
            access: widget.access,
            onDecision: decision,
            onEdit: () async {
              await editMaterial(
                context,
                widget.api,
                widget.session,
                kind: 'application',
                seed: record,
              );
              if (mounted) load();
            },
          ),
          if (allowed('inbound') &&
              ['receipt', 'closed'].contains(record['status']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
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
                            '${record['number']} · ${(record['requisition'] as Json?)?['project'] ?? record['text']}',
                      },
                      draftKey: 'inbound-${record['id']}',
                    );
                    if (mounted) load();
                  },
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('另行办理关联入库'),
                ),
              ),
            ),
          if ((inbound['total'] as int? ?? 0) > 0) ...[
            heading('关联入库追溯'),
            for (final doc in objects(inbound['items']))
              linkedDocument(doc, summary: !allowed('inbound')),
            pagination(inbound['total'] as int),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MaterialStatusBadge(
              status: materialText(record, 'status'),
              prominent: true,
            ),
            Text(
              '${record['number']}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 24,
          runSpacing: 6,
          children: [
            Text('申请人：${record['owner']}'),
            if (materialText(record, 'submitted').isNotEmpty)
              Text('提交时间：${materialTime(record['submitted'])}'),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: const Color(0xffd3dbe3)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('申请内容', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
              SelectableText(
                materialText(record, 'text'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (record['status'] == 'pending' &&
                (record['owner_id'] != widget.access['user_id'] ||
                    allowed('request')) &&
                allowed('approve')) ...[
              FilledButton.icon(
                style: _detailActionStyle(context),
                onPressed: busy ? null : () => decision('approved'),
                icon: const Icon(Icons.check_circle_outline, size: 20),
                label: const Text('通过申请'),
              ),
              OutlinedButton.icon(
                style: _detailActionStyle(context, reject: true),
                onPressed: busy ? null : () => decision('rejected'),
                icon: const Icon(Icons.undo, size: 20),
                label: const Text('驳回申请'),
              ),
            ],
            if (record['status'] == 'rejected' &&
                record['owner_id'] == widget.access['user_id'] &&
                allowed('request'))
              FilledButton.icon(
                style: _detailActionStyle(context),
                icon: const Icon(Icons.edit_note, size: 20),
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
                label: const Text('修改并重新提交'),
              ),
            if (record['status'] == 'approved' && allowed('inbound'))
              FilledButton.icon(
                style: _detailActionStyle(context),
                icon: const Icon(Icons.inventory_2_outlined, size: 20),
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
                label: const Text('关联入库'),
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
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${record['number']}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            MaterialStatusBadge(
              status: materialText(record, 'status'),
              prominent: true,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 20,
          runSpacing: 6,
          children: [
            Text('经办人：${record['owner']}'),
            Text('时间：${materialTime(record['created'])}'),
          ],
        ),
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
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: data?['can_read_application'] == true
                    ? () => openRelated('application', {
                        'id': record['application_id'],
                      })
                    : null,
                child: Text('查看来源申请 · 批准版本 ${record['application_version']}'),
              ),
            ),
        ],
        if (kind == 'return')
          TextButton(
            onPressed: () =>
                openRelated('document', {'id': record['source_id']}),
            child: const Text('返回原出库单'),
          ),
        heading('物料明细'),
        for (final line in objects(record['lines'])) lineCard(line),
        if (materialText(record, 'known_amount').isNotEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                detailValue(
                  record['missing_prices'] == 0 ? '合计金额' : '已知金额小计',
                  '¥${record['known_amount']}',
                  size: 24,
                ),
                if ((record['missing_prices'] as int? ?? 0) > 0)
                  Text('缺价 ${record['missing_prices']} 行，未计入合计'),
              ],
            ),
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
        ],
        if (materialText(record, 'signature_id').isNotEmpty) ...[
          heading('经办人签名'),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 220,
              child: MaterialAssetView(
                api: widget.api,
                id: materialText(record, 'signature_id'),
                height: 80,
              ),
            ),
          ),
        ],
        if ((record['asset_ids'] as List? ?? []).isNotEmpty) ...[
          heading('入库凭证'),
          const Text('点击缩略图查看大图，可缩放'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final entry in (record['asset_ids'] as List).asMap().entries)
                SizedBox(
                  width: 160,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MaterialAssetView(
                        api: widget.api,
                        id: '${entry.value}',
                        height: 104,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '凭证 ${entry.key + 1}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
        if (kind == 'inbound' && (record['asset_ids'] as List? ?? []).isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('未附入库凭证'),
          ),
        if (kind == 'outbound') ...[
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
    final current = stockRecord ?? selectedRecord;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${current['name']} · ${current['specification']}',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 32,
          runSpacing: 10,
          children: [
            detailValue('该分类库存', '${current['quantity']} ${current['unit']}'),
            detailValue(
              '各类总库存',
              '${current['total_quantity']} ${current['unit']}',
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text('分类：${current['stock_category']}'),
        Text(
          '预警值：${current['warning']} ${current['unit']}${current['low'] == true ? ' · 低库存' : ''}',
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
  Widget build(BuildContext context) => MaterialWorkflowDialog(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: application
            ? (MediaQuery.sizeOf(context).height * .80).clamp(0.0, 780.0)
            : MediaQuery.sizeOf(context).height * .9,
      ),
      child: SizedBox(
        key: const Key('material-detail-content'),
        width: application ? 1320 : 820,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (trail.isNotEmpty)
                    IconButton(
                      tooltip: '返回上一张单据',
                      onPressed: busy ? null : backToRelated,
                      icon: const Icon(Icons.arrow_back),
                    ),
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
              const Divider(height: 20),
              if (loading || busy) const LinearProgressIndicator(),
              if (error != null) materialError(error!, retry: load),
              if (message != null) Text(message!),
              Flexible(
                child: data == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        controller: detailScroll,
                        child: DefaultTextStyle.merge(
                          style: const TextStyle(fontSize: 15, height: 1.4),
                          child: stock
                              ? stockBody()
                              : application
                              ? applicationBody()
                              : documentBody(),
                        ),
                      ),
              ),
            ],
          ),
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
  late final keyName =
      'decision-${widget.record['id']}-${widget.record['version']}-${widget.record['status']}-${widget.decision}';
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
          if (widget.record['workflow'] == 2) 'stage': widget.record['status'],
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
  Widget build(BuildContext context) => MaterialWorkflowAlert(
    title: Text(
      widget.decision == 'received'
          ? '确认清单已阅'
          : widget.decision == 'approved'
          ? (widget.record['status'] == 'review' ? '审核通过' : '批准申请')
          : '退回编制人',
    ),
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
            if (widget.decision == 'received')
              const Text('确认您已看到这份清单，记录本人签名并完成本次申请。'),
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
        style: _detailActionStyle(context),
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('返回'),
      ),
      FilledButton(
        style: _detailActionStyle(context),
        onPressed: busy ? null : submit,
        child: Text(draft.pending == null ? '确认' : '重试确认'),
      ),
    ],
  );
}
