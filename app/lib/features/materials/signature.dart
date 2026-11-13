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

  Future<void> save() async {
    if (image == null || signature == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final selected = image!;
      if (selected.assetID == null) {
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
      final result = await draft.submit(
        widget.api,
        '/api/v1/account/signature',
        {'asset_id': selected.assetID, 'version': signature!['version']},
      );
      if (mounted) {
        setState(() {
          signature = result;
          image = null;
          message = '签名已保存，历史单据保持原签名。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
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
        const Text('审批通过、出库和退库使用您的签名。更换不会改变历史单据。'),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          materialError(error!, retry: signature == null ? load : null),
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
            if (image != null)
              FilledButton(
                onPressed: busy || signature == null ? null : save,
                child: Text(draft.pending != null ? '重试确认保存' : '保存签名'),
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
      ],
    ),
  );
}

Future<void> showPersonalSignature(BuildContext context, PlatformApi api) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        title: const Text('个人签名'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: PersonalSignature(api: api)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(dialog),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
