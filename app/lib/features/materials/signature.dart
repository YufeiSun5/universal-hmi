import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../platform/material_files.dart';
import '../../platform/process_files.dart';
import '../../platform/material_unload.dart';
import 'session.dart';
import 'widgets.dart';

class PersonalSignature extends StatefulWidget {
  const PersonalSignature({super.key, required this.api, this.pickImage});
  final PlatformApi api;
  final Future<List<ProcessFile>> Function()? pickImage;
  @override
  State<PersonalSignature> createState() => _PersonalSignatureState();
}

class _PersonalSignatureState extends State<PersonalSignature> {
  Json? signature;
  MaterialImageDraft? image;
  bool loading = true, busy = false;
  String? error, message;
  List<Json> history = [];
  int historyTotal = 0, historyOffset = 0;
  bool historyLoading = true;
  String? historyError;
  late final draft = MaterialDraft(onChanged: () {});
  late final void Function() removeUnload;
  bool closing = false;
  bool get dirty => image != null || busy || draft.pending != null;
  @override
  void initState() {
    super.initState();
    removeUnload = watchMaterialUnload(() => dirty);
    load();
  }

  @override
  void dispose() {
    removeUnload();
    super.dispose();
  }

  Future<void> close() async {
    if (closing) return;
    if (busy || draft.pending != null) {
      setState(() => error = '签名保存尚未确认，请等待或重试确认保存后再关闭。');
      return;
    }
    closing = true;
    try {
      if (!dirty ||
          await materialConfirm(
            context,
            '放弃未保存的签名？',
            '新选择的图片尚未保存，关闭后将保留原签名。',
          )) {
        if (mounted) Navigator.pop(context);
      }
    } finally {
      closing = false;
    }
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.api.request('GET', '/api/v1/account/signature');
      if (mounted) setState(() => signature = data);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => loading = false);
    if (mounted) await loadHistory();
  }

  Future<void> loadHistory() async {
    setState(() {
      historyLoading = true;
      historyError = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/account/signature/history',
        query: {'offset': historyOffset, 'limit': 10},
      );
      if (mounted) {
        setState(() {
          history = objects(result['items']);
          historyTotal = result['total'] as int? ?? 0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => historyError = '$e');
    }
    if (mounted) setState(() => historyLoading = false);
  }

  Future<void> choose() async {
    try {
      final files =
          await (widget.pickImage?.call() ??
              pickMaterialImages(multiple: false));
      if (files.isNotEmpty && mounted) {
        setState(() {
          image = MaterialImageDraft(files.single);
          error = null;
          message = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> remove() async {
    if (busy || signature == null || draft.pending != null) return;
    if (!await materialConfirm(
          context,
          '删除当前签名？',
          '删除后，新审批通过、出库和退库需要重新设置签名。历史签名版本及已签单据仍然保留。',
        ) ||
        !mounted) {
      return;
    }
    await save(deleting: true);
  }

  Future<void> save({bool deleting = false}) async {
    if (signature == null || busy) return;
    deleting = draft.pending?['delete'] == true || deleting;
    if (!deleting && image == null && draft.pending == null) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final selected = image;
      if (!deleting &&
          draft.pending == null &&
          selected != null &&
          selected.assetID == null) {
        final data = await widget.api.request(
          'POST',
          '$materialsBase/assets',
          body: {
            'operation_id': selected.operation,
            'kind': 'signature',
            'name': selected.file.name,
            'data': base64Encode(selected.file.bytes),
          },
        );
        selected.assetID = materialText(data, 'id');
      }
      final result = await draft
          .submit(widget.api, '/api/v1/account/signature', {
            if (deleting) 'delete': true else 'asset_id': selected?.assetID,
            'version': signature!['version'],
          });
      if (mounted) {
        setState(() {
          signature = result;
          image = null;
          message = deleting ? '当前签名已删除，历史版本和已签单据保留。' : '签名已保存，历史单据保持原签名。';
          historyOffset = 0;
        });
        await loadHistory();
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
      if (e is PlatformRequestException && e.statusCode == 409 && mounted) {
        try {
          final current = await widget.api.request(
            'GET',
            '/api/v1/account/signature',
          );
          if (mounted) {
            setState(() {
              signature = current;
              error = '签名已在其他窗口更改，当前版本已刷新。请核对后重新确认；所选图片已保留。';
            });
          }
          if (mounted) await loadHistory();
        } catch (_) {
          if (mounted) setState(() => error = '签名版本冲突，刷新失败。请重试加载当前签名，所选图片已保留。');
        }
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '个人签名',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('每人一份当前签名，确认审批通过、出库和退库时自动带上。创建、更新和删除均保留历史版本。'),
        if (signature != null &&
            materialText(signature!, 'asset_id').isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('当前签名 · 第 ${signature!['version']} 版'),
          ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          materialError(
            error!,
            retry: !busy && draft.pending == null ? load : null,
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(message!),
          ),
        if (image != null)
          Container(
            height: 100,
            color: Colors.white,
            alignment: Alignment.centerLeft,
            child: Image.memory(
              image!.file.bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('图片内容无效，请重新选择'),
            ),
          )
        else if (signature != null &&
            materialText(signature!, 'asset_id').isNotEmpty)
          MaterialAssetView(
            api: widget.api,
            id: materialText(signature!, 'asset_id'),
            height: 100,
          )
        else if (!loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('尚未上传签名'),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy || loading || draft.pending != null
                  ? null
                  : choose,
              child: const Text('选择签名图片'),
            ),
            if (image != null || draft.pending != null)
              FilledButton(
                onPressed: busy || signature == null ? null : () => save(),
                child: Text(
                  draft.pending?['delete'] == true
                      ? '重试确认删除'
                      : draft.pending != null
                      ? '重试确认保存'
                      : '保存签名',
                ),
              ),
            if (image == null &&
                signature != null &&
                materialText(signature!, 'asset_id').isNotEmpty)
              TextButton.icon(
                onPressed: busy || loading || draft.pending != null
                    ? null
                    : remove,
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除当前签名'),
              ),
            if (image != null)
              TextButton(
                onPressed: busy || draft.pending != null
                    ? null
                    : () => setState(() => image = null),
                child: const Text('取消更换'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '签名历史（$historyTotal）',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (historyLoading) const LinearProgressIndicator(),
        if (historyError != null)
          materialError(historyError!, retry: loadHistory),
        if (!historyLoading && historyError == null && history.isEmpty)
          const Text('暂无历史版本'),
        for (final version in history)
          ExpansionTile(
            key: ValueKey('signature-history-${version['version']}'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              '第 ${version['version']} 版 · ${switch (version['action']) {
                'created' => '创建',
                'updated' => '更新',
                'deleted' => '删除',
                _ => '既有签名',
              }}',
            ),
            subtitle: Text(
              materialText(version, 'created').isEmpty
                  ? '原始时间未记录'
                  : materialTime(version['created']),
            ),
            children: [
              if (materialText(version, 'asset_id').isNotEmpty)
                MaterialAssetView(
                  api: widget.api,
                  id: materialText(version, 'asset_id'),
                  height: 100,
                )
              else
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('此版本删除了当前签名，之前的版本仍保留。'),
                ),
            ],
          ),
        if (historyTotal > 10)
          Row(
            children: [
              IconButton(
                tooltip: '上一页签名历史',
                onPressed: historyLoading || historyOffset == 0
                    ? null
                    : () {
                        historyOffset = (historyOffset - 10).clamp(
                          0,
                          historyTotal,
                        );
                        loadHistory();
                      },
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${historyOffset ~/ 10 + 1}'),
              IconButton(
                tooltip: '下一页签名历史',
                onPressed: historyLoading || historyOffset + 10 >= historyTotal
                    ? null
                    : () {
                        historyOffset += 10;
                        loadHistory();
                      },
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    ),
  );
}
