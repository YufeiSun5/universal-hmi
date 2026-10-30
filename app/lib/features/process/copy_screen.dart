import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

String _canonical(Object? value) {
  Object? ordered(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(item[key])};
    }
    if (item is List) return item.map(ordered).toList();
    if (item is num) return item.toDouble();
    return item;
  }

  return jsonEncode(ordered(value));
}

/// Saves an independent, unbound snapshot without changing the source session.
Future<ScreenDocument?> copyProcessScreen(
  BuildContext context,
  PlatformApi api,
  ScreenDocument source,
  List<String> stations,
) {
  if (source.kind != 'process') return Future.value();
  return showDialog<ScreenDocument>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CopyScreen(api: api, source: source, stations: stations),
  );
}

class _CopyScreen extends StatefulWidget {
  const _CopyScreen({
    required this.api,
    required this.source,
    required this.stations,
  });
  final PlatformApi api;
  final ScreenDocument source;
  final List<String> stations;
  @override
  State<_CopyScreen> createState() => _CopyScreenState();
}

class _CopyScreenState extends State<_CopyScreen> {
  late final name = TextEditingController(
    text:
        '${widget.source.name.substring(0, widget.source.name.length.clamp(0, 77))} 副本',
  );
  late String station = widget.source.station;
  // Retain identity across retries; a failed response is verified by reading it.
  late final snapshot = widget.source.instantiate(widget.source.station);
  bool saving = false;
  String? failure;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    if (name.text.trim().isEmpty || name.text.trim().length > 80) {
      setState(() => failure = '请输入不超过80字的画面名称');
      return;
    }
    setState(() {
      saving = true;
      failure = null;
    });
    try {
      final next = snapshot.copy(name: name.text.trim(), station: station);
      next.checkGeometry();
      Json result;
      try {
        result = await widget.api.request(
          'PUT',
          '/api/v1/screens/${next.id}',
          body: next.toJson(),
        );
      } catch (_) {
        // A response may be lost after persistence. Read only; never overwrite
        // a document whose identity/content differs from the submitted copy.
        try {
          final persisted = ScreenDocument.fromJson(
            await widget.api.request('GET', '/api/v1/screens/${next.id}'),
          );
          if (persisted.revision <= 0 ||
              _canonical(persisted.copy(revision: 0).toJson()) !=
                  _canonical(next.toJson())) {
            rethrow;
          }
          result = persisted.toJson();
        } catch (_) {
          rethrow;
        }
      }
      if (mounted) {
        Navigator.pop(
          context,
          next.copy(revision: (result['revision'] as num).toInt()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          failure = '复制失败：$e；表单仍保留，可重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('复制工艺图'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('来源：${widget.source.name}'),
              const SizedBox(height: 16),
              TextField(
                key: const Key('copy-screen-name'),
                controller: name,
                enabled: !saving,
                maxLength: 80,
                autofocus: true,
                decoration: const InputDecoration(labelText: '新画面名称'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('copy-screen-station'),
                initialValue: station,
                decoration: const InputDecoration(labelText: '目标范围'),
                items: [
                  for (final scope in {
                    '',
                    ...widget.stations,
                    widget.source.station,
                  })
                    DropdownMenuItem(
                      value: scope,
                      child: Text(scope.isEmpty ? '公共画面' : scope),
                    ),
                ],
                onChanged: saving ? null : (v) => setState(() => station = v!),
              ),
              const SizedBox(height: 16),
              const Text(
                '创建独立画面，变量与箭头条件需重新绑定；不跟随公共布局同步。源画面及其未保存修改保持。',
                style: TextStyle(fontSize: 12),
              ),
              if (widget.source.linked)
                const Text('公共引用将复制当前显示的完整布局。', style: TextStyle(fontSize: 12)),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    failure!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('copy-screen-save'),
          onPressed: saving ? null : save,
          child: Text(saving ? '正在保存…' : '保存副本'),
        ),
      ],
    ),
  );
}
