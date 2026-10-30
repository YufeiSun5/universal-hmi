import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';
import '../../shared/table.dart';
import '../trend.dart';
import 'catalog.dart';
import 'sources.dart';

class ExternalWorkspace extends StatelessWidget {
  const ExternalWorkspace({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.screen,
    this.development = false,
    this.showPanel = false,
  });
  final ExternalCatalog catalog;
  final Json? screen;
  final bool development, showPanel;
  final ValueChanged<Json?> onOpen;
  @override
  Widget build(BuildContext context) {
    final body = screen == null
        ? development && catalog.canDevelop
              ? ExternalSources(catalog: catalog, onOpen: onOpen)
              : const Center(child: Text('从左侧选择历史画面'))
        : ExternalQuery(
            key: ValueKey('${screen!['id']}-${screen!['revision']}'),
            api: catalog.api,
            screen: screen!,
            actions: development && catalog.canDevelop
                ? [
                    IconButton(
                      tooltip: '编辑画面名称',
                      onPressed: () async {
                        final s = await editExternalScreen(
                          context,
                          catalog,
                          screen,
                        );
                        if (s != null) onOpen(s);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      tooltip: '删除外数据画面',
                      onPressed: () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text('删除画面 ${screen!['name']}？'),
                            content: const Text('外部数据库及其历史数据不会被修改。'),
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
                        if (yes != true) return;
                        try {
                          await catalog.api.request(
                            'DELETE',
                            '/api/v1/external/screens/${screen!['id']}',
                            body: {'revision': screen!['revision']},
                          );
                          await catalog.load();
                          onOpen(null);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString())),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ]
                : const [],
          );
    return showPanel
        ? Material(
            color: Theme.of(context).colorScheme.surface,
            textStyle: Theme.of(context).textTheme.bodyMedium,
            child: Row(
              children: [
                SizedBox(
                  width: DesktopSidebar.width,
                  child: ExternalDataPanel(
                    catalog: catalog,
                    onOpen: onOpen,
                    selectedID: screen?['id'] as String?,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          )
        : body;
  }
}

class ExternalQuery extends StatefulWidget {
  const ExternalQuery({
    super.key,
    required this.api,
    required this.screen,
    this.actions = const [],
  });
  final PlatformApi api;
  final Json screen;
  final List<Widget> actions;
  @override
  State<ExternalQuery> createState() => _ExternalQueryState();
}

class _ExternalQueryState extends State<ExternalQuery> {
  late final date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  late final from = TextEditingController(text: '${date.text}T00:00');
  late final to = TextEditingController(
    text:
        '${DateTime.now().add(const Duration(days: 1)).toIso8601String().substring(0, 10)}T00:00',
  );
  List<Json> stations = [];
  String station = '', columnFilter = '';
  String? error, stationError;
  Json? result;
  bool loading = true, busy = false;
  int generation = 0, offset = 0, pointIndex = 0;
  bool get hourly => widget.screen['kind'] == 'hourly';
  bool get trend => widget.screen['kind'] == 'trend';
  @override
  void initState() {
    super.initState();
    loadStations();
  }

  @override
  void dispose() {
    generation++;
    date.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> loadStations() async {
    setState(() {
      loading = true;
      stationError = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/external/screens/${widget.screen['id']}/stations',
      );
      if (!mounted) return;
      setState(() {
        stations = objects(data['items']);
        station = stations.isEmpty ? '' : '${stations.first['code']}';
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          stationError = e.toString();
          loading = false;
        });
      }
    }
  }

  void changed() {
    generation++;
    setState(() {
      result = null;
      error = null;
      offset = 0;
      busy = false;
    });
  }

  Future<void> query([int nextOffset = 0]) async {
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/external/screens/${widget.screen['id']}/query',
        body: {
          'station': station,
          'date': date.text.trim(),
          'from': from.text.trim(),
          'to': to.text.trim(),
          'offset': nextOffset,
        },
      );
      if (!mounted || request != generation) return;
      setState(() {
        result = data;
        offset = nextOffset;
        pointIndex = 0;
        busy = false;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  String timeText(dynamic value) => value == null
      ? '—'
      : value
            .toString()
            .replaceFirst('T', ' ')
            .replaceFirst(RegExp(r'(Z|[+-]\d\d:\d\d)$'), '');
  String qualityText(Json r) => r['sample_time'] == null
      ? '缺测'
      : switch (r['quality']) {
          1 => '有效',
          2 => '有效 (2)',
          null => '未知质量',
          _ => '无效 (${r['quality']})',
        };
  Widget input(TextEditingController c, String label, double width) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      enabled: !busy,
      onChanged: (_) => changed(),
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final points = objects(result?['points']), rows = objects(result?['rows']);
    final columns = [
      for (var i = 0; i < points.length; i++)
        if ('${points[i]['name']} ${points[i]['code']}'.toLowerCase().contains(
          columnFilter.toLowerCase(),
        ))
          i,
    ];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
          child: Row(
            children: [
              Icon(externalIcon(widget.screen['kind'] as String?), size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '${widget.screen['name']}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ...widget.actions,
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('$station-${stations.length}'),
                  initialValue: station.isEmpty ? null : station,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '外部站区',
                    isDense: true,
                  ),
                  items: stations
                      .map(
                        (s) => DropdownMenuItem(
                          value: '${s['code']}',
                          child: Text(
                            '${s['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: busy || loading
                      ? null
                      : (v) {
                          station = v!;
                          changed();
                        },
                ),
              ),
              if (hourly)
                input(date, '日期 YYYY-MM-DD', 160)
              else ...[
                input(from, '开始 YYYY-MM-DDTHH:mm', 200),
                input(to, '结束（不含）', 200),
              ],
              FilledButton.icon(
                onPressed: busy || loading || station.isEmpty
                    ? null
                    : () => query(),
                icon: const Icon(Icons.search, size: 17),
                label: const Text('查询'),
              ),
              if (busy)
                TextButton(onPressed: changed, child: const Text('取消等待')),
            ],
          ),
        ),
        if (loading || busy) const LinearProgressIndicator(minHeight: 2),
        if (stationError != null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    stationError!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
                OutlinedButton(
                  onPressed: loadStations,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(error!, style: TextStyle(color: colors.error)),
          ),
        if (result != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '第 ${offset ~/ 500 + 1} 页 · ${rows.length} 条 · UTC${(result!['utc_offset_minutes'] as num) >= 0 ? '+' : ''}${(result!['utc_offset_minutes'] as num) / 60}',
                ),
                Text(
                  hourly
                      ? '整点 ±30 分钟最近采样 · 等距取早'
                      : '最多 31 天 · 每页 500 条${trend ? ' · 曲线仅表示当前页' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (trend && points.isNotEmpty)
                  SizedBox(
                    width: 280,
                    child: DropdownButtonFormField<int>(
                      key: ValueKey('point-$pointIndex-${points.length}'),
                      initialValue: pointIndex,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '趋势测点',
                        isDense: true,
                      ),
                      items: [
                        for (var i = 0; i < points.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '${points[i]['name']} (${points[i]['unit']})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => pointIndex = v!),
                    ),
                  ),
                if (!trend)
                  SizedBox(
                    width: 210,
                    child: TextField(
                      onChanged: (v) => setState(() => columnFilter = v),
                      decoration: const InputDecoration(
                        hintText: '筛选测点列',
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trend && points.isNotEmpty && rows.isNotEmpty)
            Expanded(
              flex: 2,
              child: Trend(
                key: ValueKey('${widget.screen['id']}-$offset-$pointIndex'),
                rows: [
                  for (final r in rows)
                    {
                      'point_id': '${points[pointIndex]['code']}',
                      'source_time': r['sample_time'] ?? r['target_time'],
                      // A bad marker is retained to break the existing chart path; it is never displayed as a value.
                      'value':
                          double.tryParse(
                            '${(r['values'] as List)[pointIndex]}',
                          ) ??
                          0,
                      'quality':
                          (r['values'] as List)[pointIndex] != null &&
                              const [1, 2].contains(r['quality'])
                          ? 'good'
                          : 'bad',
                    },
                ],
                names: {
                  '${points[pointIndex]['code']}':
                      '${points[pointIndex]['name']} (${points[pointIndex]['unit']})',
                },
              ),
            ),
          Expanded(
            flex: 3,
            child: DenseTable(
              key: ValueKey(
                '${widget.screen['id']}-$offset-${columns.join(',')}',
              ),
              headers: [
                if (hourly) '目标时间',
                '实际采样时间',
                '质量',
                if (hourly) '匹配',
                for (final i in columns)
                  '${points[i]['name']}${points[i]['unit'] == '' ? '' : ' (${points[i]['unit']})'}',
              ],
              rowCount: rows.length,
              rowBuilder: (i) {
                final r = rows[i];
                return [
                  if (hourly) timeText(r['target_time']),
                  timeText(r['sample_time']),
                  qualityText(r),
                  if (hourly)
                    const {
                          'exact': '整点',
                          'nearest': '最近',
                          'missing': '缺测',
                        }[r['match']] ??
                        '未知',
                  for (final p in columns)
                    (r['values'] as List)[p]?.toString() ?? '—',
                ];
              },
              initialWidths: [
                if (hourly) 174,
                190,
                95,
                if (hourly) 75,
                for (final _ in columns) 155,
              ],
              emptyLabel: '此时间范围没有历史采样',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '按当前测点定义查询 · 无效/缺测显示 —',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                if (!hourly) ...[
                  TextButton(
                    onPressed: offset == 0 || busy
                        ? null
                        : () => query(offset - 500),
                    child: const Text('上一页'),
                  ),
                  TextButton(
                    onPressed: result!['has_more'] != true || busy
                        ? null
                        : () => query(offset + 500),
                    child: const Text('下一页'),
                  ),
                ],
              ],
            ),
          ),
        ] else
          Expanded(
            child: Center(
              child: Text(
                busy
                    ? '正在查询外部历史…'
                    : loading
                    ? '正在读取外部站区…'
                    : stationError != null || error != null
                    ? '未取得查询结果'
                    : stations.isEmpty
                    ? '数据源没有启用的站区'
                    : '选择站区与日期后查询',
              ),
            ),
          ),
      ],
    );
  }
}
