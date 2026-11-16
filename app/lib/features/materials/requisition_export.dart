import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../shared/pagination.dart';
import 'widgets.dart';
import 'session.dart';

/// Selection is restricted to closed requisitions. The service revalidates every
/// selected version and rejects the entire export if any record is ineligible.
class RequisitionExportDialog extends StatefulWidget {
  const RequisitionExportDialog({super.key, required this.api});
  final PlatformApi api;
  @override
  State<RequisitionExportDialog> createState() =>
      _RequisitionExportDialogState();
}

class _RequisitionExportDialogState extends State<RequisitionExportDialog> {
  final search = TextEditingController();
  final selected = <String, Json>{};
  List<Json> records = [];
  int total = 0, offset = 0;
  bool loading = true, exporting = false;
  String? error, message;
  @override
  void initState() {
    super.initState();
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
        '$materialsBase/applications',
        query: {
          'status': 'closed',
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
        error = '一次最多选择50张申请，请分批导出。';
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
        '$materialsBase/applications/export',
        body: {
          'items': [
            for (final record in selected.values)
              {'id': record['id'], 'version': record['version']},
          ],
        },
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
                const Expanded(
                  child: Text(
                    '批量导出已闭环申请',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: exporting ? null : () => Navigator.pop(context),
                  tooltip: '关闭批量导出',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              '一个 Excel，每张申请一个工作表，包含清单及四方签名。',
              style: TextStyle(color: Color(0xff647581)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: search,
                    enabled: !loading && !exporting,
                    decoration: const InputDecoration(
                      labelText: '搜索已闭环申请',
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
                            if (r['status'] == 'closed') choose(r, true);
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
                  ? Center(child: Text(loading ? '正在查询…' : '没有符合条件的已闭环申请'))
                  : ListView.separated(
                      itemCount: records.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = records[i];
                        return CheckboxListTile(
                          value: selected.containsKey(materialText(r, 'id')),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged:
                              loading || exporting || r['status'] != 'closed'
                              ? null
                              : (value) => choose(r, value == true),
                          title: Text(
                            materialApplicationLabel(r),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${r['number']} · 第 ${r['version']} 版 · ${r['owner']} · ${materialTime(r['submitted'])}',
                          ),
                          secondary: const MaterialStatusBadge(
                            status: 'closed',
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
