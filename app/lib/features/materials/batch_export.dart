import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../shared/pagination.dart';
import 'widgets.dart';
import 'session.dart';

/// The service revalidates the complete selection before generating a file.
class MaterialBatchExportDialog extends StatefulWidget {
  const MaterialBatchExportDialog({
    super.key,
    required this.api,
    this.kind = 'applications',
    this.filters = const {},
  });
  final PlatformApi api;
  final String kind;
  final Json filters;
  @override
  State<MaterialBatchExportDialog> createState() =>
      _MaterialBatchExportDialogState();
}

class _MaterialBatchExportDialogState extends State<MaterialBatchExportDialog> {
  bool get applications => widget.kind == 'applications';
  String get label => applications
      ? '已闭环申请'
      : widget.kind == 'inbound'
      ? '收料单'
      : '领料单';
  bool eligible(Json r) =>
      applications ? r['status'] == 'closed' : r['kind'] == widget.kind;
  final search = TextEditingController();
  final selected = <String, Json>{};
  List<Json> records = [];
  int total = 0, offset = 0;
  bool loading = true, exporting = false;
  String? error, message;
  @override
  void initState() {
    super.initState();
    search.text = materialText(widget.filters, 'search');
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '$materialsBase/${widget.kind}',
        query: {
          ...widget.filters,
          if (applications) 'status': 'closed',
          'search': search.text.trim(),
          'offset': offset,
          'limit': 50,
        },
      );
      if (!mounted) return;
      setState(() {
        records = objects(result['items']);
        total = result['total'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          records = [];
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void choose(Json record, bool value) {
    final id = materialText(record, 'id');
    setState(() {
      error = null;
      if (!value) {
        selected.remove(id);
      } else if (selected.length >= 50) {
        error = '一次最多选择50张单据，请分批导出。';
      } else {
        selected[id] = record;
      }
    });
  }

  Future<void> export() async {
    setState(() {
      exporting = true;
      error = null;
      message = null;
    });
    try {
      final result = await widget.api.request(
        'POST',
        '$materialsBase/${applications ? 'applications' : 'documents'}/export',
        body: applications
            ? {
                'items': [
                  for (final record in selected.values)
                    {'id': record['id'], 'version': record['version']},
                ],
              }
            : {'kind': widget.kind, 'ids': selected.keys.toList()},
      );
      final saved = await saveFile(
        base64Decode(materialText(result, 'data')),
        materialText(result, 'name'),
      );
      if (mounted) setState(() => message = saved ? '已交给文件保存功能。' : '已取消保存。');
    } catch (e) {
      if (mounted) setState(() => error = '导出失败，可重试。$e');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialWorkflowDialog(
    child: SizedBox(
      width: 1000,
      height: (MediaQuery.sizeOf(context).height * .78).clamp(0.0, 700.0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '批量导出$label',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: exporting ? null : () => Navigator.pop(context),
                  tooltip: '关闭批量导出',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              applications
                  ? '一个 Excel，每张申请一个工作表，包含清单及四方签名。'
                  : '同一工作表按勾选顺序从上到下排列，明细行自动扩展。沿用列表日期和分类筛选，导出整张单据。',
              style: const TextStyle(color: Color(0xff647581)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: search,
                    enabled: !loading && !exporting,
                    decoration: InputDecoration(
                      labelText: applications ? '搜索工程编号、单号或内容' : '搜索单号或内容',
                      isDense: true,
                    ),
                    onSubmitted: (_) {
                      offset = 0;
                      load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: loading || exporting
                      ? null
                      : () {
                          offset = 0;
                          load();
                        },
                  child: const Text('查询'),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('已选 ${selected.length} / 50 张'),
                TextButton(
                  onPressed: loading || exporting || records.isEmpty
                      ? null
                      : () {
                          for (final r in records) {
                            if (eligible(r)) choose(r, true);
                          }
                        },
                  child: const Text('选择本页'),
                ),
                TextButton(
                  onPressed: exporting || selected.isEmpty
                      ? null
                      : () => setState(selected.clear),
                  child: const Text('清空选择'),
                ),
              ],
            ),
            if (loading || exporting) const LinearProgressIndicator(),
            if (error != null) materialError(error!),
            if (message != null) Text(message!),
            Expanded(
              child: records.isEmpty
                  ? Center(child: Text(loading ? '正在查询…' : '没有符合条件的$label'))
                  : ListView.separated(
                      itemCount: records.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = records[i];
                        return CheckboxListTile(
                          value: selected.containsKey(materialText(r, 'id')),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: loading || exporting || !eligible(r)
                              ? null
                              : (value) => choose(r, value == true),
                          title: Text(
                            applications
                                ? materialApplicationLabel(r)
                                : materialText(r, 'number'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            applications
                                ? '${r['number']} · 第 ${r['version']} 版 · ${r['owner']} · ${materialTime(r['submitted'])}'
                                : '${r['owner']} · ${materialTime(r['created'])} · ${objects(r['lines']).length} 条明细',
                          ),
                          secondary: MaterialStatusBadge(
                            status: materialText(r, 'status'),
                          ),
                        );
                      },
                    ),
            ),
            PaginationBar(
              total: total,
              offset: offset,
              pageSize: 50,
              busy: loading || exporting,
              onChanged: (v) {
                offset = v;
                load();
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: exporting || selected.isEmpty ? null : export,
                icon: const Icon(Icons.download_outlined),
                label: Text('导出所选 ${selected.length} 张'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
