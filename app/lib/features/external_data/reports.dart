import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../shared/table.dart';
import 'catalog.dart';

const _alarmColumns = {
  'event_time': '事件时间',
  'alarm_time': '报警发生时间',
  'tag': '变量名称',
  'event_type': '事件类型',
  'alarm_value': '报警值',
  'resume_value': '恢复值',
  'operator': '操作人',
  'description': '报警描述',
  'comment': '变量说明',
  'group': '分组',
  'alarm_type': '报警类型',
  'priority': '优先级',
  'limit_value': '限值',
};

class AlarmWorkspace extends StatefulWidget {
  const AlarmWorkspace({super.key, required this.catalog});
  final ExternalCatalog catalog;
  @override
  State<AlarmWorkspace> createState() => _AlarmWorkspaceState();
}

class _AlarmWorkspaceState extends State<AlarmWorkspace> {
  String? selected;
  @override
  void initState() {
    super.initState();
    if (!widget.catalog.loaded) Future.microtask(widget.catalog.load);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.catalog,
    builder: (context, _) {
      final c = widget.catalog,
          screens = c.screens.where((s) => s['kind'] == 'alarm').toList();
      if (c.loading) return const Center(child: CircularProgressIndicator());
      if (c.error != null) {
        return Center(
          child: TextButton(onPressed: c.load, child: Text('${c.error} · 重试')),
        );
      }
      if (screens.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              c.canDevelop
                  ? '请在外数据中新建「历史报警」画面，选择小时报使用的数据源。'
                  : '没有已授权的历史报警画面，请联系工程管理员。',
            ),
          ),
        );
      }
      final screen = screens.firstWhere(
        (s) => s['id'] == selected,
        orElse: () => screens.first,
      );
      return Column(
        children: [
          if (screens.length > 1)
            DropdownButton<String>(
              value: screen['id'],
              items: [
                for (final s in screens)
                  DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text('${s['name']}'),
                  ),
              ],
              onChanged: (v) => setState(() => selected = v),
            ),
          Expanded(
            child: ReportQuery(
              key: ValueKey('${screen['id']}-${screen['revision']}'),
              api: c.api,
              screen: screen,
              autoQuery: true,
            ),
          ),
        ],
      );
    },
  );
}

class ReportQuery extends StatefulWidget {
  const ReportQuery({
    super.key,
    required this.api,
    required this.screen,
    this.autoQuery = false,
    this.actions = const [],
  });
  final PlatformApi api;
  final Json screen;
  final bool autoQuery;
  final List<Widget> actions;
  @override
  State<ReportQuery> createState() => _ReportQueryState();
}

class _ReportQueryState extends State<ReportQuery> {
  bool get alarm => widget.screen['kind'] == 'alarm';
  String get path => '/api/v1/external/screens/${widget.screen['id']}';
  late Json criteria;
  List<Json> stations = [];
  bool loading = true, busy = false, exporting = false;
  int serial = 0;
  String? error, directoryNote;
  Json? result;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now(), today = DateTime(now.year, now.month, now.day);
    String stamp(DateTime t) => t.toIso8601String().substring(0, 16);
    criteria = {
      'station': '',
      'from': stamp(alarm ? today.subtract(const Duration(days: 6)) : today),
      'to': stamp(today.add(const Duration(days: 1))),
      'offset': 0,
      if (!alarm) ...{'interval': 5, 'page_size': 500},
      if (alarm) ...{'event_type': '', 'tag': ''},
    };
    initialize();
  }

  Future<void> initialize() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (!alarm) {
        final data = await widget.api.request('GET', '$path/stations');
        stations = objects(data['items']);
        // Directory labels are optional project metadata. Only an unambiguous exact name may enrich a SQL station.
        List<Json> labels = [];
        try {
          labels = objects(
            (await widget.api.request('GET', '/api/v1/live-overview'))['rows'],
          );
        } catch (_) {
          directoryNote = '总览站点分组不可用，可按数据库站区查询';
        }
        for (final s in stations) {
          final matches = labels
              .where((r) => r['station'] == s['name'])
              .toList();
          final label = matches.length == 1
              ? matches.single
              : <String, dynamic>{};
          s.addAll({
            'site': label['site'] ?? '未归属',
            'plant': label['name'] ?? s['name'],
            'area': label['area'] ?? s['name'],
          });
        }
        if (stations.isNotEmpty) criteria['station'] = stations.first['code'];
      }
      if (!mounted) return;
      setState(() => loading = false);
      if (widget.autoQuery && (alarm || stations.isNotEmpty)) {
        await query(criteria);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString();
        });
      }
    }
  }

  Future<Json> fetch(Json request) =>
      widget.api.request('POST', '$path/query', body: request);
  Future<void> query(Json request) async {
    final token = ++serial;
    setState(() {
      criteria = request;
      busy = true;
      result = null;
      error = null;
    });
    try {
      final all = request['page_size'] == 0;
      final data = await fetch({...request, if (all) 'page_size': 1000});
      if (all) {
        final rows = objects(data['rows']);
        await for (final page in remainingPages(data, token)) {
          rows.addAll(objects(page['rows']));
        }
        data['rows'] = rows;
        data['has_more'] = false;
      }
      if (mounted && token == serial) setState(() => result = data);
    } catch (e) {
      if (mounted && token == serial) setState(() => error = e.toString());
    } finally {
      if (mounted && token == serial) setState(() => busy = false);
    }
  }

  int get size => alarm
      ? 500
      : criteria['page_size'] == 0
      ? 21600
      : criteria['page_size'] as int;
  final hiddenGroups = <String>{};
  String pointGroup(Json p) {
    final name = p['name'].toString(), split = name.indexOf('_');
    return split > 0
        ? name.substring(0, split)
        : name == '室外温度'
        ? '环境'
        : '其他';
  }

  List<int> visiblePoints(Json data) {
    final points = snapshotObjects(data['points']);
    return [
      for (var i = 0; i < points.length; i++)
        if (!hiddenGroups.contains(pointGroup(points[i]))) i,
    ];
  }

  List<String> headers(Json data, List<int> indices) {
    if (alarm) return _alarmColumns.values.toList();
    final points = snapshotObjects(data['points']);
    return [
      '目标时间',
      '实际采样时间',
      '匹配',
      '质量',
      for (final i in indices)
        '${points[i]['name']}${points[i]['unit'] == '' ? '' : ' (${points[i]['unit']})'}',
    ];
  }

  List<String> cells(Json row, List<int> indices) {
    if (alarm) {
      return [for (final k in _alarmColumns.keys) row[k]?.toString() ?? '—'];
    }
    String stamp(dynamic v) =>
        v
            ?.toString()
            .replaceFirst('T', ' ')
            .replaceFirst(RegExp(r'(Z|[+-]\d\d:\d\d)$'), '') ??
        '—';
    return [
      stamp(row['target_time']),
      stamp(row['sample_time']),
      const {'exact': '精确', 'nearest': '最近', 'missing': '缺测'}[row['match']] ??
          '未知',
      switch (row['quality']) {
        1 => '有效',
        2 => '有效 (2)',
        null => '—',
        final v => '无效 ($v)',
      },
      for (final i in indices) row['values'][i]?.toString() ?? '—',
    ];
  }

  Stream<Json> remainingPages(Json first, int token) async* {
    String signature(Json p) => jsonEncode([
      p['points'],
      p['mapping_id'],
      p['source_revision'],
      p['screen_revision'],
      p['total'],
    ]);
    final expected = signature(first), total = first['total'] as int;
    for (var offset = 1000; offset < total; offset += 1000) {
      if (!mounted || token != serial) return;
      final page = await fetch({
        ...criteria,
        'offset': offset,
        'page_size': 1000,
      });
      if (signature(page) != expected ||
          page['offset'] != offset ||
          (page['rows'] as List).length != (total - offset).clamp(0, 1000)) {
        throw StateError('测点定义、画面或数据页已变化，请重新查询');
      }
      yield page;
    }
  }

  Future<void> export() async {
    final first = result!, token = ++serial;
    setState(() {
      exporting = true;
      error = null;
    });
    String csv(String s) {
      final value =
          RegExp(r'^[\s]*[=+@-]').hasMatch(s) && num.tryParse(s) == null
          ? "'$s"
          : s;
      return '"${value.replaceAll('"', '""')}"';
    }

    final output = StringBuffer('\uFEFF');
    void line(List<String> cells) =>
        output.write('${cells.map(csv).join(',')}\r\n');
    try {
      final indices = visiblePoints(first);
      line(headers(first, indices));
      final page = await fetch({...criteria, 'offset': 0, 'page_size': 1000});
      if (!mounted || token != serial) return;
      for (final key in [
        'points',
        'mapping_id',
        'source_revision',
        'screen_revision',
        'total',
      ]) {
        if (jsonEncode(page[key]) != jsonEncode(first[key])) {
          throw StateError('测点或查询配置已改变，请重新查询');
        }
      }
      for (final r in objects(page['rows'])) {
        line(cells(r, indices));
      }
      await for (final next in remainingPages(page, token)) {
        if (!mounted || token != serial) return;
        for (final r in objects(next['rows'])) {
          line(cells(r, indices));
        }
      }
      if (!mounted || token != serial) return;
      await saveFile(
        Uint8List.fromList(utf8.encode(output.toString())),
        '标准历史-${criteria['station']}-${criteria['from'].toString().substring(0, 10)}.csv',
      );
    } catch (e) {
      if (mounted && token == serial) setState(() => error = e.toString());
    } finally {
      if (mounted && token == serial) setState(() => exporting = false);
    }
  }

  Future<void> configure() async {
    final next = await showDialog<Json>(
      context: context,
      builder: (_) => _Criteria(
        initial: criteria,
        stations: stations,
        alarm: alarm,
        note: directoryNote,
      ),
    );
    if (mounted && next != null) await query(next);
  }

  @override
  Widget build(BuildContext context) {
    final data = result,
        rows = data == null
            ? <Json>[]
            : snapshotObjects(data[alarm ? 'events' : 'rows']);
    final indices = data == null ? <int>[] : visiblePoints(data);
    final possible = alarm || stations.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${widget.screen['name']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              OutlinedButton.icon(
                onPressed: loading || busy || exporting || !possible
                    ? null
                    : configure,
                icon: const Icon(Icons.tune),
                label: const Text('查询条件'),
              ),
              FilledButton(
                onPressed: loading || busy || exporting || !possible
                    ? null
                    : () => query({...criteria, 'offset': 0}),
                child: const Text('查询'),
              ),
              if (!alarm && data != null)
                PopupMenuButton<String>(
                  tooltip: '选择显示分组',
                  enabled: !exporting,
                  icon: const Icon(Icons.view_column_outlined),
                  itemBuilder: (_) => [
                    for (final group in snapshotObjects(
                      data['points'],
                    ).map(pointGroup).toSet())
                      CheckedPopupMenuItem(
                        value: group,
                        checked: !hiddenGroups.contains(group),
                        child: Text(group),
                      ),
                  ],
                  onSelected: (g) => setState(() {
                    if (!hiddenGroups.remove(g)) hiddenGroups.add(g);
                  }),
                ),
              if (!alarm && data != null)
                TextButton(
                  onPressed: exporting ? null : export,
                  child: const Text('导出全部 CSV'),
                ),
              if (busy || exporting)
                TextButton(
                  onPressed: () => setState(() {
                    serial++;
                    busy = false;
                    exporting = false;
                  }),
                  child: const Text('取消等待'),
                ),
              ...widget.actions,
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '${alarm ? '数据库原始时间' : (stations.where((s) => s['code'] == criteria['station']).firstOrNull?['name'] ?? '未选站区')} · ${criteria['from']} 至 ${criteria['to']}（不含）${alarm ? '' : ' · 每 ${criteria['interval']} 分钟'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (loading || busy || exporting)
          const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (data != null) ...[
          Expanded(
            child: DenseTable(
              key: ValueKey(jsonEncode([criteria, headers(data, indices)])),
              headers: headers(data, indices),
              rowCount: rows.length,
              rowBuilder: (i) => cells(rows[i], indices),
              initialWidths: [
                for (final h in headers(data, indices))
                  h.contains('时间')
                      ? 185
                      : h.contains('变量') || h.contains('描述')
                      ? 210
                      : 125,
              ],
              emptyLabel: alarm ? '所选条件没有报警事件' : '所选条件没有目标时间点',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  ' 第 ${(criteria['offset'] as int) ~/ size + 1} 页 · ${rows.length} 条${alarm ? '' : ' / 共 ${data['total']} 条'}',
                ),
              ),
              TextButton(
                onPressed: exporting || criteria['offset'] == 0
                    ? null
                    : () => query({
                        ...criteria,
                        'offset': criteria['offset'] - size,
                      }),
                child: const Text('上一页'),
              ),
              TextButton(
                onPressed: exporting || data['has_more'] != true
                    ? null
                    : () => query({
                        ...criteria,
                        'offset': criteria['offset'] + size,
                      }),
                child: const Text('下一页'),
              ),
            ],
          ),
        ] else
          Expanded(
            child: Center(
              child: !possible && !loading
                  ? TextButton(
                      onPressed: initialize,
                      child: const Text('没有可用站区 · 重新读取'),
                    )
                  : Text(
                      loading
                          ? '正在加载…'
                          : busy
                          ? '正在查询…'
                          : error != null
                          ? '未取得查询结果'
                          : '选择条件后查询',
                    ),
            ),
          ),
      ],
    );
  }
}

class _Criteria extends StatefulWidget {
  const _Criteria({
    required this.initial,
    required this.stations,
    required this.alarm,
    this.note,
  });
  final Json initial;
  final List<Json> stations;
  final bool alarm;
  final String? note;
  @override
  State<_Criteria> createState() => _CriteriaState();
}

class _CriteriaState extends State<_Criteria> {
  late final Json draft = {...widget.initial, 'offset': 0};
  late Json station = widget.stations.firstWhere(
    (s) => s['code'] == draft['station'],
    orElse: () => {},
  );
  Widget select(
    String label,
    String value,
    List<String> list,
    ValueChanged<String> change,
  ) => DropdownButtonFormField<String>(
    key: ValueKey('$label-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final v in list)
        DropdownMenuItem(
          value: v,
          child: Text(v == '' ? '全部' : v, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v != null) setState(() => change(v));
    },
  );
  Widget input(String label, String key, {bool number = false}) =>
      TextFormField(
        initialValue: '${draft[key]}',
        decoration: InputDecoration(labelText: label),
        keyboardType: number ? TextInputType.number : TextInputType.text,
        onChanged: (v) => draft[key] = number ? int.tryParse(v) ?? 0 : v.trim(),
      );
  @override
  Widget build(BuildContext context) {
    final stations = widget.stations;
    final plants = stations.where((s) => s['site'] == station['site']).toList();
    final areas = plants.where((s) => s['plant'] == station['plant']).toList();
    return AlertDialog(
      title: Text(widget.alarm ? '报警查询条件' : '标准历史查询条件'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.alarm) ...[
                if (widget.note != null) Text(widget.note!),
                select(
                  '站所',
                  '${station['site']}',
                  stations.map((s) => '${s['site']}').toSet().toList(),
                  (v) => station = stations.firstWhere((s) => s['site'] == v),
                ),
                select(
                  '换热站',
                  '${station['plant']}',
                  plants.map((s) => '${s['plant']}').toSet().toList(),
                  (v) => station = plants.firstWhere((s) => s['plant'] == v),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey(station['code']),
                  initialValue: station['code'],
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '区域'),
                  items: [
                    for (final s in areas)
                      DropdownMenuItem(
                        value: s['code'] as String,
                        child: Text('${s['area']} · ${s['code']}'),
                      ),
                  ],
                  onChanged: (v) => setState(
                    () => station = areas.firstWhere((s) => s['code'] == v),
                  ),
                ),
              ],
              input('开始 YYYY-MM-DDTHH:mm[:ss]', 'from'),
              input('结束（不含）', 'to'),
              if (widget.alarm) ...[
                select('事件类型', draft['event_type'], [
                  '',
                  '报警',
                  '报警确认',
                  '报警恢复',
                ], (v) => draft['event_type'] = v),
                input('变量名称包含', 'tag'),
              ] else ...[
                input('间隔（分钟）', 'interval', number: true),
                select(
                  '每页条数',
                  draft['page_size'] == 0 ? '全部' : '${draft['page_size']}',
                  ['500', '700', '1000', '全部'],
                  (v) => draft['page_size'] = int.tryParse(v) ?? 0,
                ),
                const Text('最多15天。半个间隔内匹配最近采样，等距取早。'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            ...draft,
            if (!widget.alarm) 'station': station['code'],
          }),
          child: const Text('应用并查询'),
        ),
      ],
    );
  }
}
