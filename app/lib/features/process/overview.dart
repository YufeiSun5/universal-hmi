import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'diagram.dart';
import 'session.dart';

class ProcessOverviewPanel extends StatefulWidget {
  const ProcessOverviewPanel({
    super.key,
    required this.api,
    required this.session,
    required this.definitions,
    required this.live,
    required this.online,
    required this.onOpenDevelopment,
    required this.onOpenProcess,
  });
  final PlatformApi api;
  final ProcessSession session;
  final Map<String, Json> definitions, live;
  final bool online;
  final VoidCallback onOpenDevelopment, onOpenProcess;
  @override
  State<ProcessOverviewPanel> createState() => _ProcessOverviewPanelState();
}

class _ProcessOverviewPanelState extends State<ProcessOverviewPanel> {
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.session.controller.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    try {
      await widget.session.ensureLoaded(widget.api);
    } catch (e) {
      if (mounted) error = '工艺画面读取失败：$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    widget.session.controller.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: TextButton(
          onPressed: () {
            setState(() {
              loading = true;
              error = null;
            });
            load();
          },
          child: Text('$error · 重试'),
        ),
      );
    }
    final editor = widget.session.controller, doc = editor.document;
    if (doc.nodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('本站还没有工艺画面', style: TextStyle(fontSize: 12)),
            TextButton.icon(
              onPressed: widget.onOpenDevelopment,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建模板'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ProcessDiagram(
            document: doc,
            definitions: widget.definitions,
            live: widget.live,
            online: widget.online,
            title: '${doc.name}${editor.dirty ? ' · 草稿' : ''}',
          ),
        ),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              TextButton(
                onPressed: widget.onOpenProcess,
                child: Text(
                  '本站画面 · ${widget.session.screens.length}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onOpenDevelopment,
                child: const Text('编辑模板', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
