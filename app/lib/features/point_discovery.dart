import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../shared/api.dart';

Future<int?> discoverPoints(
  BuildContext context,
  PlatformApi api, {
  required List<Json> sources,
  required List<String> stations,
  String station = '',
  String? sourceId,
}) => showDialog<int>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PointDiscoveryDialog(
    api: api,
    sources: sources,
    stations: stations,
    station: station,
    sourceId: sourceId,
  ),
);

class PointDiscoveryDialog extends StatefulWidget {
  const PointDiscoveryDialog({
    super.key,
    required this.api,
    required this.sources,
    required this.stations,
    this.station = '',
    this.sourceId,
  });
  final PlatformApi api;
  final List<Json> sources;
  final List<String> stations;
  final String station;
  final String? sourceId;

  @override
  State<PointDiscoveryDialog> createState() => _PointDiscoveryDialogState();
}

class _DiscoveryChoice {
  _DiscoveryChoice(this.row)
    : name = '${row['name'] ?? row['path']}',
      type = '${row['data_type'] ?? ''}',
      selected =
          (row['existing_id'] ?? '') == '' && (row['data_type'] ?? '') != '';
  Json row;
  String name, type;
  bool selected, editedType = false, editedName = false;
  bool get existing => (row['existing_id'] ?? '') != '';
}

class _PointDiscoveryDialogState extends State<PointDiscoveryDialog> {
  static const pageSize = 200;
  final search = TextEditingController();
  late final TextEditingController station;
  late String sourceId;
  List<_DiscoveryChoice> choices = [];
  final selection = <String, _DiscoveryChoice>{};
  bool autoSelect = true, selecting = false;
  int selectionProgress = 0;
  String? selectionNote;
  Json page = {};
  int offset = 0, sequence = 0, scanSeconds = 0;
  bool loading = false, connecting = false, saving = false;
  String? error;
  Timer? debounce, scanTimer;

  bool get locked => connecting || saving || selecting;
  bool get connected => page['connected'] == true;
  int get selectedCount =>
      selection.values.where((c) => c.selected && !c.existing).length;
  String get sourcePath => '/api/v1/sources/${Uri.encodeComponent(sourceId)}';
  String keyOf(Json row) => jsonEncode([row['topic'], row['path']]);
  bool get wildcardSearch => search.text.contains(RegExp(r'[*?]'));

  @override
  void initState() {
    super.initState();
    station = TextEditingController(text: widget.station);
    sourceId =
        widget.sourceId ??
        (widget.sources.isEmpty ? '' : '${widget.sources.first['id']}');
    if (sourceId.isNotEmpty) unawaited(load(reset: true));
  }

  @override
  void dispose() {
    sequence++;
    debounce?.cancel();
    scanTimer?.cancel();
    search.dispose();
    station.dispose();
    super.dispose();
  }

  void resetSelection() {
    selection.clear();
    selectionNote = null;
    autoSelect = true;
  }

  Future<void> load({bool reset = false, bool selectAll = false}) async {
    if (sourceId.isEmpty) return;
    final request = ++sequence;
    setState(() {
      loading = true;
      error = null;
      if (reset) choices = [];
    });
    try {
      final result = await widget.api.request(
        'GET',
        '$sourcePath/discovery',
        query: {'q': search.text.trim(), 'offset': offset, 'limit': pageSize},
      );
      if (!mounted || request != sequence) return;
      final next = objects(result['items']).map((row) {
        final key = keyOf(row);
        final old = selection[key];
        if (old == null) {
          final choice = _DiscoveryChoice(row);
          if (!autoSelect) choice.selected = false;
          selection[key] = choice;
          return choice;
        }
        old.row = row;
        if (!old.editedType) old.type = '${row['data_type'] ?? ''}';
        if (!old.editedName) old.name = '${row['name'] ?? row['path']}';
        if (old.existing || old.type.isEmpty) old.selected = false;
        return old;
      }).toList();
      setState(() {
        page = result;
        choices = next;
        loading = false;
      });
      if (selectAll) await selectMatching();
    } catch (e) {
      if (!mounted || request != sequence) return;
      stopScan();
      setState(() {
        loading = false;
        error = '读取扫描结果失败：$e';
      });
    }
  }

  Future<void> selectMatching() async {
    if (locked || loading || sourceId.isEmpty) return;
    stopScan();
    debounce?.cancel();
    final request = ++sequence;
    final query = search.text.trim();
    setState(() {
      selecting = true;
      selectionProgress = 0;
      error = null;
      selectionNote = null;
    });
    try {
      final collected = <String, Json>{};
      String? revision;
      int? expected;
      var skippedExisting = 0, skippedType = 0;
      for (var start = 0; start < (expected ?? 1); start += 500) {
        final result = await widget.api.request(
          'GET',
          '$sourcePath/discovery',
          query: {'q': query, 'offset': start, 'limit': 500},
        );
        if (!mounted || request != sequence) return;
        final total = (result['total'] as num).toInt();
        final currentRevision = result['revision'] as String?;
        if (total > 20000 ||
            currentRevision == null ||
            (expected != null &&
                (expected != total || revision != currentRevision))) {
          throw const FormatException('扫描目录已变化，请重新全选。');
        }
        expected = total;
        revision = currentRevision;
        final rows = objects(result['items']);
        if (rows.length != math.min(500, total - start)) {
          throw const FormatException('扫描结果不完整，请重新全选。');
        }
        for (final row in rows) {
          collected[keyOf(row)] = row;
        }
        setState(() => selectionProgress = collected.length);
      }
      if (collected.length != expected) {
        throw const FormatException('扫描目录已变化，请重新全选。');
      }
      final next = <String, _DiscoveryChoice>{};
      for (final entry in collected.entries) {
        final c = selection[entry.key] ?? _DiscoveryChoice(entry.value);
        c.row = entry.value;
        if (!c.editedType) c.type = '${c.row['data_type'] ?? ''}';
        if (!c.editedName) c.name = '${c.row['name'] ?? c.row['path']}';
        c.selected = !c.existing && c.type.isNotEmpty;
        if (c.existing) {
          skippedExisting++;
        } else if (c.type.isEmpty) {
          skippedType++;
        }
        next[entry.key] = c;
      }
      setState(() {
        selection
          ..clear()
          ..addAll(next);
        choices = [
          for (final c in choices)
            if (next[keyOf(c.row)] != null) next[keyOf(c.row)]!,
        ];
        autoSelect = false;
        selectionNote =
            '已跨页选中 $selectedCount 项 · 跳过已添加 $skippedExisting 项、类型待确认 $skippedType 项';
      });
    } catch (e) {
      if (mounted && request == sequence) {
        setState(() => error = '全选未完成，原选择保留：$e');
      }
    } finally {
      if (mounted && request == sequence) setState(() => selecting = false);
    }
  }

  void stopScan() {
    scanTimer?.cancel();
    scanTimer = null;
    if (mounted) setState(() => scanSeconds = 0);
  }

  Future<void> scan() async {
    if (locked || sourceId.isEmpty) return;
    debounce?.cancel();
    stopScan();
    setState(() => error = null);
    if (!connected) {
      setState(() => connecting = true);
      try {
        if ('${page['state'] ?? ''}'.startsWith('offline')) {
          await widget.api.request('POST', '$sourcePath/disconnect');
        }
        await widget.api.request('POST', '$sourcePath/connect');
      } catch (e) {
        if (mounted) setState(() => error = '连接失败：$e。请检查数据源地址和订阅主题。');
        return;
      } finally {
        if (mounted) setState(() => connecting = false);
      }
    }
    if (!mounted) return;
    await load();
    if (!mounted || error != null) return;
    setState(() => scanSeconds = 8);
    scanTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || saving) return;
      setState(() => scanSeconds--);
      if (!loading) unawaited(load());
      if (scanSeconds <= 0) stopScan();
    });
  }

  Future<void> rename(_DiscoveryChoice choice) async {
    final controller = TextEditingController(text: choice.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('变量名称'),
        content: TextField(
          key: const Key('discovery-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '添加后的名称'),
          onSubmitted: (_) => Navigator.pop(context, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // Let the dialog's closing animation release its TextField first.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (!mounted || value == null) return;
    setState(() {
      choice.name = value;
      choice.editedName = true;
    });
  }

  Future<void> add() async {
    final target = station.text.trim();
    if (target.isEmpty || utf8.encode(target).length > 128) {
      setState(() => error = '请选择或输入有效的目标站点（最多 128 字节）。');
      return;
    }
    final selected = selection.values
        .where((c) => c.selected && !c.existing)
        .toList();
    if (selected.isEmpty) return;
    stopScan();
    debounce?.cancel();
    sequence++; // A late scan response must not change this batch.
    setState(() {
      saving = true;
      loading = false;
      error = null;
    });
    try {
      final current = objects(
        (await widget.api.request('GET', '/api/v1/points'))['items'],
      );
      final names = current
          .where((p) => p['station'] == target)
          .map((p) => p['name'])
          .toSet();
      final inputs = <Json>[];
      final mappings = <String, Json>{
        for (final p in current)
          if (p['source_type'] == 'mqtt' && p['source_id'] == sourceId)
            jsonEncode([p['topic'] ?? '', p['source_path']]): p,
      };
      for (final choice in selected) {
        final row = choice.row;
        final existing =
            mappings[keyOf(row)] ?? mappings[jsonEncode(['', row['path']])];
        if (existing != null) {
          choice.row = {
            ...row,
            'existing_id': existing['id'],
            'existing_station': existing['station'],
          };
          choice.selected = false;
          continue;
        }
        final name = choice.name.trim();
        if (name.isEmpty || utf8.encode(name).length > 256) {
          throw FormatException('请修改变量名称：${row['path']}（名称最多 256 字节）。');
        }
        if (!names.add(name)) throw FormatException('站点内名称重复：$name。请点击铅笔修改名称。');
        if (!['BOOL', 'INT', 'FLOAT', 'STRING'].contains(choice.type)) {
          throw FormatException('请确认变量类型：$name');
        }
        inputs.add({
          'station': target,
          'name': name,
          'data_type': choice.type,
          'source_type': 'mqtt',
          'source_id': sourceId,
          'source_path': row['path'],
          'topic': row['topic'],
          'writable': false,
          'rw_mode': 'R',
          'scale_factor': 1,
          'offset': 0,
          'unit': '',
          'stale_ms': 5000,
        });
      }
      if (inputs.isEmpty) {
        if (mounted) setState(() => error = '这些变量已添加，无需重复保存。');
        return;
      }
      final result = await widget.api.request(
        'POST',
        '/api/v1/points/batch',
        body: {'items': inputs},
      );
      if (mounted) Navigator.pop(context, objects(result['items']).length);
    } catch (e) {
      if (mounted) setState(() => error = '添加未确认成功：$e。可重新扫描核对已添加状态后重试。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget row(_DiscoveryChoice choice) {
    final r = choice.row;
    final enabled = !locked && !choice.existing;
    final quality = switch (r['quality']) {
      'good' => '正常',
      'bad' => '坏质量',
      _ => '${r['quality'] ?? '未知'}',
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      decoration: BoxDecoration(
        color: choice.selected && !choice.existing
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .045)
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: ValueKey('discovery-check-${r['path']}'),
            value: choice.selected && !choice.existing,
            onChanged: enabled && choice.type.isNotEmpty
                ? (v) => setState(() => choice.selected = v ?? false)
                : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  choice.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Tooltip(
                  message: '${r['path']}\n主题：${r['topic']}',
                  child: Text(
                    '${r['path']} · ${r['topic']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  choice.existing
                      ? '已添加 · ${r['existing_station']}'
                      : '${r['preview']} · $quality${r['retained'] == true ? ' · 保留消息' : ''}${r['type_status'] == 'conflict' ? ' · 类型冲突，请确认' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: DropdownButton<String>(
              key: ValueKey('discovery-type-${r['path']}'),
              value: choice.type,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: '', child: Text('待确认')),
                DropdownMenuItem(value: 'BOOL', child: Text('布尔')),
                DropdownMenuItem(value: 'FLOAT', child: Text('浮点数')),
                DropdownMenuItem(value: 'INT', child: Text('整数')),
                DropdownMenuItem(value: 'STRING', child: Text('字符串')),
              ],
              onChanged: !enabled
                  ? null
                  : (value) => setState(() {
                      choice.type = value ?? '';
                      choice.editedType = true;
                      choice.selected = choice.type.isNotEmpty;
                    }),
            ),
          ),
          IconButton(
            tooltip: '修改变量名称',
            onPressed: enabled ? () => rename(choice) : null,
            icon: const Icon(Icons.edit_outlined, size: 17),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final total = (page['total'] as num?)?.toInt() ?? 0;
    return PopScope(
      canPop: !locked,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: math.min(1040, size.width - 24),
          height: math.min(750, size.height - 24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        Icons.playlist_add_check_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 23,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '从数据源扫描变量',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bounds) => SingleChildScrollView(
                      key: const Key('discovery-body'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width: math.min(320, bounds.maxWidth),
                                child: DropdownButtonFormField<String>(
                                  key: const Key('discovery-source'),
                                  initialValue: sourceId.isEmpty
                                      ? null
                                      : sourceId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '数据源',
                                  ),
                                  items: widget.sources
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: '${s['id']}',
                                          child: Text(
                                            '${s['name']} · ${s['protocol']}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: locked
                                      ? null
                                      : (value) {
                                          stopScan();
                                          debounce?.cancel();
                                          setState(() {
                                            sourceId = value ?? '';
                                            page = {};
                                            offset = 0;
                                            resetSelection();
                                          });
                                          unawaited(
                                            load(
                                              reset: true,
                                              selectAll: wildcardSearch,
                                            ),
                                          );
                                        },
                                ),
                              ),
                              SizedBox(
                                width: math.min(250, bounds.maxWidth),
                                child: TextField(
                                  key: const Key('discovery-station'),
                                  controller: station,
                                  enabled: !locked,
                                  decoration: InputDecoration(
                                    labelText: '添加到站点',
                                    hintText: '选择或输入站点',
                                    suffixIcon: widget.stations.isEmpty
                                        ? null
                                        : PopupMenuButton<String>(
                                            tooltip: '选择已有站点',
                                            enabled: !locked,
                                            itemBuilder: (_) => widget.stations
                                                .map(
                                                  (s) => PopupMenuItem(
                                                    value: s,
                                                    child: Text(s),
                                                  ),
                                                )
                                                .toList(),
                                            onSelected: (s) => station.text = s,
                                            icon: const Icon(
                                              Icons.arrow_drop_down,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              OutlinedButton.icon(
                                key: const Key('discovery-scan'),
                                onPressed:
                                    locked ||
                                        sourceId.isEmpty ||
                                        (loading && scanSeconds == 0)
                                    ? null
                                    : scanSeconds > 0
                                    ? stopScan
                                    : scan,
                                icon: const Icon(Icons.radar, size: 17),
                                label: Text(
                                  connecting
                                      ? '正在连接…'
                                      : scanSeconds > 0
                                      ? '停止刷新（${scanSeconds}s）'
                                      : connected
                                      ? '重新扫描'
                                      : '连接并扫描',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '发现所选来源已发布的变量；未发布的变量暂无法发现。类型按收到的值识别，数值默认浮点，可修改。',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            '来源连接会保持；扫描不写设备、不自动应用配置。${page['state'] == null || page['state'] == '' ? '' : ' 状态：${page['state']}'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            key: const Key('discovery-search'),
                            controller: search,
                            enabled: !locked,
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search, size: 18),
                              hintText: '输入 * 全选；例如 *温度*,*压力* 或 泵?运行',
                              helperMaxLines: 2,
                              helperText:
                                  '* 任意字符 · ? 单个字符 · 逗号分隔多个条件 · 普通文字查找；通配筛选自动跨页全选，修改筛选会重置选择',
                            ),
                            onChanged: (_) {
                              stopScan();
                              debounce?.cancel();
                              sequence++;
                              setState(() {
                                choices = [];
                                offset = 0;
                                resetSelection();
                                loading = true;
                              });
                              debounce = Timer(
                                const Duration(milliseconds: 250),
                                () => load(
                                  reset: true,
                                  selectAll: wildcardSearch,
                                ),
                              );
                            },
                          ),
                          Wrap(
                            spacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '已发现 ${page['observed'] ?? 0} · 匹配 $total · 已选 $selectedCount',
                              ),
                              FilledButton.tonalIcon(
                                key: const Key('discovery-select-all'),
                                onPressed: locked || loading
                                    ? null
                                    : selectMatching,
                                icon: const Icon(Icons.done_all, size: 17),
                                label: const Text('全选匹配项'),
                              ),
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () => setState(() {
                                        autoSelect = false;
                                        selectionNote = null;
                                        for (final c in selection.values) {
                                          c.selected = false;
                                        }
                                      }),
                                child: const Text('清空选择'),
                              ),
                            ],
                          ),
                          if (selectionNote != null)
                            Text(
                              selectionNote!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          if (selecting)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '正在跨页选择… 已读取 $selectionProgress 项',
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => setState(() {
                                    sequence++;
                                    selecting = false;
                                    selectionNote = '已取消全选，原选择保留';
                                  }),
                                  child: const Text('取消全选'),
                                ),
                              ],
                            ),
                          if ((page['omitted_samples'] as num? ?? 0) > 0)
                            const Text('部分数据因容量或路径限制未收录，请缩小来源订阅范围后重新连接。'),
                          if ((page['metrics'] as Map?)?['decode_errors']
                              case final num errors when errors > 0)
                            Text('本次连接有 $errors 条消息无法解析，请核对来源协议与时间字段。'),
                          if (loading || selecting)
                            const LinearProgressIndicator(minHeight: 2),
                          SizedBox(
                            height: math.max(160, bounds.maxHeight - 255),
                            child: choices.isEmpty
                                ? Center(
                                    child: Text(
                                      loading
                                          ? '正在读取…'
                                          : total == 0 && search.text.isNotEmpty
                                          ? '没有匹配的变量，请更换关键字。'
                                          : connected
                                          ? '尚未收到变量。请确认订阅主题，并等待上游发布数据后重新扫描。'
                                          : '选择数据源，点击“连接并扫描”。',
                                    ),
                                  )
                                : ListView.separated(
                                    key: const Key('discovery-results'),
                                    itemCount: choices.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (_, i) => row(choices[i]),
                                  ),
                          ),
                          Wrap(
                            spacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '第 ${total == 0 ? 0 : offset + 1}–${math.min(offset + pageSize, total)} 项，共 $total 项',
                              ),
                              TextButton(
                                onPressed: locked || loading || offset == 0
                                    ? null
                                    : () {
                                        stopScan();
                                        offset = math.max(0, offset - pageSize);
                                        unawaited(load(reset: true));
                                      },
                                child: const Text('上一页'),
                              ),
                              TextButton(
                                onPressed:
                                    locked ||
                                        loading ||
                                        offset + pageSize >= total
                                    ? null
                                    : () {
                                        stopScan();
                                        offset += pageSize;
                                        unawaited(load(reset: true));
                                      },
                                child: const Text('下一页'),
                              ),
                            ],
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: SelectableText(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    const Text(
                      '保存后需点击“应用配置”生效',
                      style: TextStyle(fontSize: 11),
                    ),
                    TextButton(
                      onPressed: locked ? null : () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                    FilledButton.icon(
                      key: const Key('discovery-add'),
                      onPressed: locked || loading || selectedCount == 0
                          ? null
                          : add,
                      icon: const Icon(Icons.playlist_add, size: 17),
                      label: Text(saving ? '正在保存…' : '添加选中 ($selectedCount)'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
