import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'catalog.dart';

class ExternalSources extends StatefulWidget {
  const ExternalSources({
    super.key,
    required this.catalog,
    required this.onOpen,
  });
  final ExternalCatalog catalog;
  final ValueChanged<Json?> onOpen;
  @override
  State<ExternalSources> createState() => _ExternalSourcesState();
}

class _ExternalSourcesState extends State<ExternalSources> {
  @override
  void initState() {
    super.initState();
    if (!widget.catalog.loaded) Future.microtask(widget.catalog.load);
  }

  String? message;
  bool busy = false, failed = false;
  Future<void> edit([Json? source]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SourceEditor(catalog: widget.catalog, source: source),
    );
  }

  Future<void> test(Json source) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.catalog.api.request(
        'POST',
        '/api/v1/external/sources/${source['id']}/test',
        body: {},
      );
      if (mounted) {
        setState(() {
          message = '${source['name']}：连接及历史表结构检查通过';
          failed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = e.toString();
          failed = true;
        });
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> remove(Json source) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除数据源 ${source['name']}？'),
        content: const Text('仅删除本系统的连接配置。仍有画面引用时无法删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.catalog.api.request(
        'DELETE',
        '/api/v1/external/sources/${source['id']}',
        body: {'revision': source['revision']},
      );
      await widget.catalog.load();
    } catch (e) {
      if (mounted) {
        setState(() {
          message = e.toString();
          failed = true;
        });
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.catalog,
    builder: (context, _) {
      final c = widget.catalog;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.dns_outlined, size: 20),
                const Text(
                  '外部数据源',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : () => edit(),
                  icon: const Icon(Icons.add, size: 17),
                  label: const Text('添加 SQL Server'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || c.sources.isEmpty
                      ? null
                      : () async {
                          final s = await editExternalScreen(context, c);
                          if (s != null) widget.onOpen(s);
                        },
                  icon: const Icon(Icons.add_chart, size: 17),
                  label: const Text('添加查询画面'),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Text(
              '独立历史查询 · 直接连接外部 SQL Server · 首批支持 KIOHistory 站区采样结构',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const Divider(height: 1),
          if (busy || c.loading) const LinearProgressIndicator(minHeight: 2),
          if (message != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                message!,
                style: TextStyle(
                  color: failed
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          Expanded(
            child: c.sources.isEmpty
                ? const Center(
                    child: Text(
                      '尚未配置外部数据源\n添加连接后，可基于同一数据源创建日报、明细和趋势画面。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    itemCount: c.sources.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = c.sources[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s['name']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${s['host']}:${s['port']} / ${s['database']}  ·  ${s['encrypt'] == true ? '加密连接' : '未加密连接'}  ·  ${c.screens.where((v) => v['source_id'] == s['id']).length} 张画面',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: busy ? null : () => test(s),
                                  child: const Text('测试连接'),
                                ),
                                OutlinedButton(
                                  onPressed: busy ? null : () => edit(s),
                                  child: const Text('编辑连接'),
                                ),
                                TextButton(
                                  onPressed: busy ? null : () => remove(s),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

class _SourceEditor extends StatefulWidget {
  const _SourceEditor({required this.catalog, this.source});
  final ExternalCatalog catalog;
  final Json? source;
  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  late final name = TextEditingController(
    text: widget.source?['name'] as String? ?? '历史数据库',
  );
  late final host = TextEditingController(
    text: widget.source?['host'] as String? ?? '',
  );
  late final port = TextEditingController(
    text: '${widget.source?['port'] ?? 1433}',
  );
  late final database = TextEditingController(
    text: widget.source?['database'] as String? ?? 'KIOHistory',
  );
  late final username = TextEditingController(
    text: widget.source?['username'] as String? ?? '',
  );
  late final offset = TextEditingController(
    text: '${widget.source?['utc_offset_minutes'] ?? 480}',
  );
  final password = TextEditingController();
  late bool encrypt = widget.source?['encrypt'] != false,
      trust = widget.source?['trust_certificate'] == true;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [name, host, port, database, username, offset, password]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.catalog.api.request(
        'POST',
        '/api/v1/external/sources',
        body: {
          'id': widget.source?['id'] ?? '',
          'revision': widget.source?['revision'] ?? 0,
          'name': name.text.trim(),
          'host': host.text.trim(),
          'port': int.tryParse(port.text) ?? 0,
          'database': database.text.trim(),
          'username': username.text.trim(),
          if (password.text.isNotEmpty || widget.source == null)
            'password': password.text,
          'encrypt': encrypt,
          'trust_certificate': trust,
          'utc_offset_minutes': int.tryParse(offset.text) ?? 9999,
        },
      );
      password.clear();
      await widget.catalog.load();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString();
        });
      }
    }
  }

  Widget field(
    TextEditingController c,
    String label, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      enabled: !busy,
      obscureText: secret,
      enableSuggestions: !secret,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.source == null ? '添加外部 SQL Server' : '编辑数据源'),
    content: SizedBox(
      width: 570,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field(name, '数据源名称'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: field(host, '服务器', hint: '主机名或 IP')),
                const SizedBox(width: 14),
                Expanded(child: field(port, 'TCP 端口')),
              ],
            ),
            field(database, '数据库'),
            field(username, 'SQL Server 登录账号', hint: '使用已获授权的只读账号'),
            field(
              password,
              widget.source == null ? '登录密码' : '登录密码（留空保留）',
              secret: true,
            ),
            field(offset, '显示时区偏移（分钟）', hint: '中国标准时间 480；历史采样按 UTC 存储'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('加密连接'),
              value: encrypt,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      encrypt = v!;
                      if (!encrypt) trust = false;
                    }),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('信任服务器证书'),
              subtitle: const Text('仅用于已核验的自签名证书；默认校验证书。'),
              value: trust,
              onChanged: busy || !encrypt
                  ? null
                  : (v) => setState(() => trust = v!),
            ),
            const SizedBox(height: 10),
            const Text(
              '数据结构：Station / Point / StationSample。保存后使用“测试连接”检查连接及表结构。',
              style: TextStyle(fontSize: 12),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? '保存中…' : '保存连接'),
      ),
    ],
  );
}
