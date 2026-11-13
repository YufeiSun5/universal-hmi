import 'package:flutter/material.dart';
import '../../shared/pagination.dart';
import '../../shared/api.dart';
import 'detail.dart';
import 'session.dart';
import 'widgets.dart';

String materialChainKind(String kind) =>
    const {
      'application': '申请入库链',
      'outbound': '出库退库链',
      'inbound': '独立入库',
      'transfer': '库存转类',
    }[kind] ??
    kind;
String materialNodeKind(String kind) =>
    const {
      'submit': '提交申请',
      'resubmit': '修改重提',
      'approved': '审批通过',
      'rejected': '审批驳回',
    }[kind] ??
    materialKind(kind);

Future<void> showMaterialChain(
  BuildContext context,
  PlatformApi api,
  MaterialsSession session, {
  required Json record,
  required Json access,
}) => showDialog<void>(
  context: context,
  builder: (_) => MaterialChainDetail(
    api: api,
    session: session,
    record: record,
    access: access,
  ),
);

class MaterialChainDetail extends StatefulWidget {
  const MaterialChainDetail({
    super.key,
    required this.api,
    required this.session,
    required this.record,
    required this.access,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json record, access;
  @override
  State<MaterialChainDetail> createState() => _MaterialChainDetailState();
}

class _MaterialChainDetailState extends State<MaterialChainDetail> {
  Json? data;
  bool loading = true;
  String? error;
  int offset = 0;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.api.request(
        'GET',
        '$materialsBase/chains/${widget.record['kind']}/${widget.record['id']}',
        query: {'offset': offset, 'limit': 30},
      );
      if (mounted) {
        setState(() => data = value);
        if (scroll.hasClients) scroll.jumpTo(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          data = null;
        });
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Widget line(Json line, {bool remaining = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${line['name']} · ${line['specification']} · ${line['quantity']} ${line['unit']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          '分类：${line['category']}${materialText(line, 'target_category').isEmpty ? '' : ' → ${line['target_category']}'}',
        ),
        if (remaining)
          Text(
            '已退 ${line['returned']} · 剩余可退 ${line['remaining']} ${line['unit']}',
          ),
        if (materialText(line, 'price').isNotEmpty)
          Text('单价 ${line['price']} · 金额 ${line['amount']}'),
      ],
    ),
  );
  Widget node(Json n, int index) {
    final app = n['application'] as Json?;
    final doc = n['document'] as Json?;
    final summary = n['summary_only'] == true;
    final signature = materialText(app ?? doc ?? {}, 'signature_id');
    final state = materialText(app ?? doc ?? {}, 'status');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: const Color(0xffdce6ee),
                  child: Text(
                    '${offset + index + 1}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff41647f),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(width: 1, height: 30, color: const Color(0xffc4cdd4)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfff6f8fa),
                border: Border.all(color: const Color(0xffd8e0e6)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        materialNodeKind(materialText(n, 'kind')),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (state.isNotEmpty) MaterialStatusBadge(status: state),
                      if (app != null) Text('版本 ${app['version']}'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText('${n['number']}'),
                  Text(
                    '${materialTime(n['created'])}${materialText(n, 'owner').isEmpty ? '' : ' · ${n['owner']}'}',
                  ),
                  if (summary)
                    const Text(
                      '当前权限可查看入库摘要',
                      style: TextStyle(color: Color(0xff647581)),
                    ),
                  if (app != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(materialText(app, 'text')),
                    if (materialText(app, 'reason').isNotEmpty)
                      Text('审批意见：${app['reason']}'),
                  ],
                  if (doc != null) ...[
                    if (materialText(doc, 'purpose').isNotEmpty)
                      Text('用途：${doc['purpose']}'),
                    if (materialText(doc, 'recipient').isNotEmpty)
                      Text('领料人：${doc['recipient']}'),
                    if (materialText(doc, 'notes').isNotEmpty)
                      Text('备注：${doc['notes']}'),
                    for (final l in objects(doc['lines'])) line(l),
                    if (!summary &&
                        materialText(doc, 'known_amount').isNotEmpty)
                      Text(
                        '${doc['missing_prices'] == 0 ? '合计金额' : '已知金额小计'}：${doc['known_amount']}${(doc['missing_prices'] as int? ?? 0) > 0 ? '（缺价 ${doc['missing_prices']} 行）' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (materialText(doc, 'application_id').isNotEmpty)
                      Text('关联批准版本 ${doc['application_version']}'),
                  ],
                  if (signature.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 160,
                          child: MaterialAssetView(
                            api: widget.api,
                            id: signature,
                            height: 64,
                          ),
                        ),
                      ),
                    ),
                  if (doc != null &&
                      !summary &&
                      (doc['asset_ids'] as List? ?? []).isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('凭证图片（${(doc['asset_ids'] as List).length}）'),
                      children: [
                        for (final id in doc['asset_ids'] as List)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: MaterialAssetView(
                              api: widget.api,
                              id: '$id',
                              height: 180,
                            ),
                          ),
                      ],
                    ),
                  if (n['can_open'] == true)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('打开原单'),
                        onPressed: () async {
                          await showMaterialDetail(
                            context,
                            widget.api,
                            widget.session,
                            kind: materialText(n, 'reference_kind'),
                            record: {'id': n['reference_id']},
                            access: widget.access,
                          );
                          if (mounted) load();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chain = data?['chain'] as Json? ?? widget.record;
    final nodes = objects(data?['nodes']?['items']);
    final total = data?['nodes']?['total'] as int? ?? 0;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 900,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '操作日志 · ${materialChainKind(materialText(chain, 'kind'))}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新链路',
                    onPressed: loading ? null : load,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '关闭链路',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (error != null) materialError(error!, retry: load),
            Flexible(
              child: SingleChildScrollView(
                controller: scroll,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${chain['number'] ?? ''} · 共 $total 个节点',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (chain['kind'] == 'application')
                      const Text('按实际提交、审批和入库记录展示，不推算到货完成率。'),
                    if (chain['kind'] == 'outbound') ...[
                      const SizedBox(height: 8),
                      MaterialStatusBadge(
                        status: materialText(chain, 'status'),
                      ),
                      for (final l in objects(chain['lines']))
                        line(l, remaining: true),
                    ],
                    const SizedBox(height: 16),
                    if (nodes.isEmpty)
                      Text(
                        loading
                            ? '正在加载链路…'
                            : error == null
                            ? '暂无节点'
                            : '链路查询未完成',
                      ),
                    for (var i = 0; i < nodes.length; i++) node(nodes[i], i),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            PaginationBar(
              total: total,
              offset: offset,
              pageSize: 30,
              busy: loading,
              label: '个节点',
              onChanged: (v) {
                offset = v;
                load();
              },
            ),
          ],
        ),
      ),
    );
  }
}
