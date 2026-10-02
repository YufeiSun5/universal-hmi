import 'dart:async';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/editors.dart';
import 'features/trend.dart';
import 'features/operational_dashboard.dart';
import 'features/history_summary.dart';
import 'features/workspace_session.dart';
import 'features/write_inspector.dart';
import 'features/variable_matrix.dart';
import 'platform/save.dart';
import 'platform/backend.dart';
import 'shared/api.dart';
import 'shared/table.dart';
import 'shared/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await startLocalBackend();
  runApp(const UniversalHmiApp());
}

Uri defaultApi() {
  const configured = String.fromEnvironment('API_BASE_URL');
  return configured.isNotEmpty
      ? Uri.parse(configured)
      : kIsWeb
      ? Uri.base
      : Uri.parse('http://127.0.0.1:18080');
}

class UniversalHmiApp extends StatefulWidget {
  const UniversalHmiApp({super.key, this.api});
  final PlatformApi? api;
  @override
  State<UniversalHmiApp> createState() => _UniversalHmiAppState();
}

class _UniversalHmiAppState extends State<UniversalHmiApp> {
  late final PlatformApi api = widget.api ?? PlatformClient(defaultApi());
  @override
  void dispose() {
    api.close();
    stopLocalBackend();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Universal HMI',
    debugShowCheckedModeBanner: false,
    theme: workspaceTheme(false),
    themeMode: ThemeMode.light,
    home: Workspace(api: api),
  );
}

const pages = [
  '变量设置',
  '跨站比较',
  '条件事件',
  '独立存储',
  '历史报表',
  '采集来源',
  '运行总览',
  '历史曲线',
  '变量监视',
];
const pageIcons = [
  Icons.tune,
  Icons.show_chart,
  Icons.bolt_outlined,
  Icons.storage_outlined,
  Icons.table_chart_outlined,
  Icons.router_outlined,
  Icons.dashboard_outlined,
  Icons.timeline,
  Icons.table_rows_outlined,
];

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.api});
  final PlatformApi api;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final search = TextEditingController(), searchFocus = FocusNode();
  final min = TextEditingController(),
      max = TextEditingController(),
      from = TextEditingController(),
      to = TextEditingController();
  Timer? timer;
  List<Json> points = [],
      history = [],
      jobs = [],
      logs = [],
      buffer = [],
      catalog = [];
  Json runtime = {}, stats = {};
  String station = '',
      query = '',
      selectedID = '',
      quality = '',
      historyPoint = '';
  int page = 6, offset = 0, boundary = 0;
  bool online = false, busy = false, polling = false, draft = false;
  double treeWidth = 214, inspectorWidth = 294;
  bool navigatorVisible = true, inspectorVisible = true;
  String? error;
  final selected = <String>{};
  int lastJobs = 0, lastEvents = 0;
  bool eventsLoaded = false, reportSamples = false;
  String? eventsError;
  final sessions = <String, StationSession>{};
  final openTabs = <String>{};
  final commandResults = <String, Json>{};
  final buckets = <String, PageStorageBucket>{};
  Map<String, Json> liveIndex = {}, pointIndex = {};
  Map<String, List<Json>> stationPoints = {};
  Map<String, int> goodCounts = {};
  List<String> stationNames = [];
  List<Json>? visibleCache;
  String visibleCacheKey = '';
  double tableScroll = 0, matrixScroll = 0, trendHeight = 208;
  bool trendVisible = false, matrixCompact = true;
  String monitorLayout = 'matrix';
  String operationalView = 'all', sourceFilter = '';
  String watchGrouping = 'source', dashboardUnit = '';
  final watched = <String>{};
  Map<String, Json> stationMetrics = {};
  Json scopedPolicy = {};
  int contextRevision = 0;
  String definitionsVersion = '';
  Set<String> knownRuntimeIDs = {};
  Future<void>? definitionLoad;

  void saveSession() {
    sessions[station] = StationSession()
      ..page = page
      ..offset = offset
      ..boundary = boundary
      ..query = query
      ..selectedID = selectedID
      ..quality = quality
      ..historyPoint = historyPoint
      ..min = min.text
      ..max = max.text
      ..from = from.text
      ..to = to.text
      ..selected = Set.of(selected)
      ..buffer = List.of(buffer)
      ..history = List.of(history)
      ..stats = Map.of(stats)
      ..scroll = tableScroll
      ..matrixScroll = matrixScroll
      ..monitorLayout = monitorLayout
      ..matrixCompact = matrixCompact
      ..trendHeight = trendHeight
      ..trendVisible = trendVisible
      ..operationalView = operationalView
      ..sourceFilter = sourceFilter
      ..watched = Set.of(watched)
      ..watchGrouping = watchGrouping
      ..dashboardUnit = dashboardUnit;
  }

  void reindexPoints() {
    saveSession();
    pointIndex = {for (final p in points) p['id'].toString(): p};
    stationPoints = {};
    for (final p in points) {
      stationPoints.putIfAbsent(p['station'].toString(), () => []).add(p);
    }
    stationNames = {
      ...stationPoints.keys,
      ...catalog.map((p) => p['station'].toString()),
    }.toList()..sort();
    for (final entry in sessions.entries) {
      final ids = entry.key.isEmpty
          ? pointIndex.keys.toSet()
          : (stationPoints[entry.key] ?? [])
                .map((p) => p['id'].toString())
                .toSet();
      final historyIDs = {
        ...ids,
        for (final p in catalog)
          if (entry.key.isEmpty || p['station'] == entry.key)
            p['id'].toString(),
      };
      entry.value.prune(ids, historyIDs);
    }
    restoreSession(sessions[station]!);
    visibleCache = null;
  }

  void restoreSession(StationSession state) {
    page = state.page;
    offset = state.offset;
    boundary = state.boundary;
    query = state.query;
    search.text = query;
    selectedID = state.selectedID;
    quality = state.quality;
    historyPoint = state.historyPoint;
    min.text = state.min;
    max.text = state.max;
    from.text = state.from;
    to.text = state.to;
    selected
      ..clear()
      ..addAll(state.selected);
    buffer = List.of(state.buffer);
    history = List.of(state.history);
    stats = Map.of(state.stats);
    tableScroll = state.scroll;
    matrixScroll = state.matrixScroll;
    monitorLayout = state.monitorLayout;
    matrixCompact = state.matrixCompact;
    trendHeight = state.trendHeight;
    trendVisible = state.trendVisible;
    operationalView = state.operationalView;
    sourceFilter = state.sourceFilter;
    watchGrouping = state.watchGrouping;
    dashboardUnit = state.dashboardUnit;
    watched
      ..clear()
      ..addAll(state.watched);
  }

  void switchStation(String next) {
    if (next == station) {
      if (next.isNotEmpty) setState(() => openTabs.add(next));
      return;
    }
    setState(() {
      saveSession();
      station = next;
      if (next.isNotEmpty) openTabs.add(next);
      contextRevision++;
      logs = [];
      eventsLoaded = false;
      eventsError = null;
      lastEvents = 0;
      restoreSession(sessions.putIfAbsent(next, StationSession.new));
      visibleCache = null;
      scopedPolicy = {};
      acceptRuntime(runtime, connectionConfirmed: false);
    });
    loadPolicy();
    if (station.isNotEmpty) loadEvents();
  }

  Future<void> loadPolicy() async {
    final scope = station;
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/storage',
        query: {if (scope.isNotEmpty) 'station': scope},
      );
      if (mounted && scope == station) setState(() => scopedPolicy = data);
    } catch (_) {
      /* A failed scoped read must never fall back to global writes. */
    }
  }

  List<Json> get scopedPoints =>
      station.isEmpty ? points : stationPoints[station] ?? const [];
  List<Json> get scopedDefinitions => historyDefinitions
      .where((p) => station.isEmpty || p['station'] == station)
      .toList();

  @override
  void initState() {
    super.initState();
    _load();
    _restore();
    timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        treeWidth = (prefs.getDouble('treeWidth') ?? 214).clamp(176, 320);
        inspectorWidth = (prefs.getDouble('inspectorWidth') ?? 294).clamp(
          230,
          400,
        );
      });
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('treeWidth', treeWidth);
      await p.setDouble('inspectorWidth', inspectorWidth);
    } catch (_) {}
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final c in [search, min, max, from, to]) {
      c.dispose();
    }
    searchFocus.dispose();
    super.dispose();
  }

  List<Json> get historyDefinitions => {
    for (final p in [...catalog, ...points]) p['id'].toString(): p,
  }.values.toList();
  List<Json> get sources => objects(runtime['sources']);
  List<Json> get rules => objects(runtime['rules']);
  List<Json> get scopedRules =>
      rules.where((r) => station.isEmpty || r['station'] == station).toList();
  List<Json> get scopedJobs =>
      jobs.where((j) => station.isEmpty || j['station'] == station).toList();
  Json get policy => Map<String, dynamic>.from(
    station.isEmpty ? runtime['policy'] as Map? ?? {} : scopedPolicy,
  );
  List<Json> get values => snapshotObjects(runtime['values']);
  Map<String, Json> get live => liveIndex;
  List<Json> get visible {
    final key = '$station|$query';
    if (visibleCache != null && key == visibleCacheKey) return visibleCache!;
    visibleCacheKey = key;
    final term = query.toLowerCase();
    return visibleCache = term.isEmpty
        ? scopedPoints
        : scopedPoints
              .where(
                (p) => '${p['station']} ${p['name']} ${p['unit']} ${p['id']}'
                    .toLowerCase()
                    .contains(term),
              )
              .toList();
  }

  Json? get current {
    final point = pointIndex[selectedID];
    return point != null && (station.isEmpty || point['station'] == station)
        ? point
        : null;
  }

  Set<String> get activeTrendIDs {
    final trendPoints = scopedPoints
        .where((p) => p['source_type'] != 'virtual' && !(p['writable'] == true))
        .toList();
    final unit = trendPoints.isEmpty ? '' : trendPoints.first['unit'];
    return selected.isNotEmpty
        ? Set<String>.of(selected)
        : trendPoints
              .where((p) => p['unit'] == unit)
              .take(2)
              .map((p) => p['id'].toString())
              .toSet();
  }

  List<Json> get trendRows {
    final ids = activeTrendIDs;
    return buffer.where((r) => ids.contains(r['point_id'])).toList();
  }

  void acceptRuntime(Json data, {bool connectionConfirmed = true}) {
    runtime = data;
    if (connectionConfirmed) online = true;
    liveIndex = {
      for (final r in snapshotObjects(data['values']))
        r['point_id'].toString(): r,
    };
    goodCounts = {};
    stationMetrics = {};
    final parsedTimes = <String, int>{};
    for (final r in liveIndex.values) {
      final scope = pointIndex[r['point_id']]?['station']?.toString();
      if (scope == null) continue;
      final metric = stationMetrics.putIfAbsent(
        scope,
        () => {
          'good': 0,
          'stale': 0,
          'bad': 0,
          'received': 0,
          'last_ms': 0,
          'last_time': '',
        },
      );
      metric['received'] = (metric['received'] as int) + 1;
      final quality = r['quality'];
      if (quality == 'good') {
        goodCounts[scope] = (goodCounts[scope] ?? 0) + 1;
      }
      if (['good', 'bad', 'stale'].contains(quality)) {
        metric[quality.toString()] = (metric[quality] as int) + 1;
      }
      final time = (r['received_time'] ?? r['source_time'] ?? '').toString();
      final millis = parsedTimes.putIfAbsent(
        time,
        () => DateTime.tryParse(time)?.millisecondsSinceEpoch ?? 0,
      );
      if (millis > (metric['last_ms'] as int)) {
        metric['last_ms'] = millis;
        metric['last_time'] = time;
      }
    }
    final ids = {...activeTrendIDs, ...watched};
    final last = <String, String>{};
    for (final r in buffer) {
      last[r['point_id'].toString()] = '${r['source_time']}|${r['quality']}';
    }
    for (final r in snapshotObjects(data['values'])) {
      final id = r['point_id'].toString();
      if (ids.contains(id) &&
          r['value'] is num &&
          last[id] != '${r['source_time']}|${r['quality']}') {
        buffer.add(r);
      }
    }
    final cutoff = DateTime.now().subtract(const Duration(minutes: 3));
    buffer = buffer
        .where(
          (r) =>
              ids.contains(r['point_id']) &&
              (DateTime.tryParse(
                    r['source_time'].toString(),
                  )?.isAfter(cutoff) ??
                  false),
        )
        .toList();
    if (buffer.length > 1800) buffer = buffer.sublist(buffer.length - 1800);
  }

  Future<void> _load() => definitionLoad ??= _loadConsistent().whenComplete(
    () => definitionLoad = null,
  );

  Future<void> _loadConsistent() async {
    try {
      // The active version must bracket the directory reads. A concurrent
      // activation otherwise pairs an old directory with a new runtime forever.
      for (var attempt = 0; attempt < 3; attempt++) {
        final before = await widget.api.request('GET', '/api/v1/runtime');
        final result = await Future.wait([
          widget.api.request('GET', '/api/v1/points'),
          widget.api.request('GET', '/api/v1/jobs'),
          widget.api.request('GET', '/api/v1/history/catalog'),
        ]);
        final after = await widget.api.request('GET', '/api/v1/runtime');
        if (!mounted) return;
        if (before['version'] != after['version']) continue;
        setState(() {
          points = snapshotObjects(result[0]['items']);
          catalog = snapshotObjects(result[2]['items']);
          definitionsVersion = (after['version'] ?? '').toString();
          knownRuntimeIDs = snapshotObjects(
            after['values'],
          ).map((r) => r['point_id'].toString()).toSet();
          reindexPoints();
          acceptRuntime(after);
          jobs = snapshotObjects(result[1]['items']);
          error = null;
        });
        await loadPolicy();
        return;
      }
      throw Exception('配置正在连续变更，目录将在下一次同步时重试');
    } catch (e) {
      if (mounted) {
        setState(() {
          online = false;
          error = e.toString();
        });
      }
    }
  }

  Future<void> _poll() async {
    if (polling) return;
    polling = true;
    try {
      final data = await widget.api.request('GET', '/api/v1/runtime');
      if (!mounted) return;
      final unknownID = snapshotObjects(data['values']).any(
        (r) =>
            !pointIndex.containsKey(r['point_id']) &&
            !knownRuntimeIDs.contains(r['point_id']),
      );
      if ((data['version'] ?? '').toString() != definitionsVersion ||
          unknownID) {
        await _load();
      } else {
        setState(() => acceptRuntime(data));
      }
      if (page == 6 &&
          station.isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch - lastEvents > 3000) {
        lastEvents = DateTime.now().millisecondsSinceEpoch;
        await loadEvents();
      }
      if (page == 4 &&
          DateTime.now().millisecondsSinceEpoch - lastJobs > 2500) {
        lastJobs = DateTime.now().millisecondsSinceEpoch;
        final j = await widget.api.request('GET', '/api/v1/jobs');
        if (mounted) setState(() => jobs = objects(j['items']));
      }
    } catch (_) {
      if (mounted) setState(() => online = false);
    } finally {
      polling = false;
    }
  }

  Future<void> act(Future<void> Function() work, {String? success}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      if (mounted && success != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add({Json? existing}) async {
    if (busy) return;
    final result = await pointEditor(
      context,
      widget.api,
      points,
      existing: existing,
      station: station.isEmpty ? null : station,
    );
    if (result != null) {
      setState(() => draft = true);
      await _load();
    }
  }

  Future<void> apply() async => act(() async {
    await widget.api.request('POST', '/api/v1/apply');
    setState(() => draft = false);
    await _load();
  }, success: '运行配置已应用');
  Future<void> demo() async => act(() async {
    await widget.api.request(
      'POST',
      '/api/v1/demo',
      body: {'enabled': runtime['demo'] != true},
    );
    await _load();
  }, success: runtime['demo'] == true ? '模拟采集已停止' : '30 个模拟站点已启动');
  Future<void> changeStorage(bool enabled) async => act(() async {
    final p = policy;
    p['enabled'] = enabled;
    await widget.api.request(
      'PUT',
      '/api/v1/storage',
      body: p,
      query: {if (station.isNotEmpty) 'station': station},
    );
    await loadPolicy();
    await _poll();
  }, success: enabled ? '独立存储已启动' : '独立存储已停止');
  Future<void> writePoint(Json p) async {
    if (p['writable'] == true) {
      selectPoint(p);
      return;
    }
    final value = await inputValue(
      context,
      p['writable'] == true ? '下设工程值 · ${p['name']}' : '输入原始值 · ${p['name']}',
      initial: number(live[p['id']]?['value']),
    );
    if (value == null || !mounted) return;
    await act(() async {
      Json result;
      if (p['writable'] == true) {
        final n = double.tryParse(value);
        if (n == null || !n.isFinite) throw Exception('请输入有限数字');
        result = await widget.api.request(
          'POST',
          '/api/v1/write',
          body: {
            'command_id': 'ui-${DateTime.now().microsecondsSinceEpoch}',
            'point_id': p['id'],
            'value': n,
            'version': runtime['version'],
          },
        );
      } else {
        Object data = value;
        if (p['data_type'] == 'BOOL') {
          if (value != 'true' && value != 'false') {
            throw Exception('请输入 true 或 false');
          }
          data = value == 'true';
        } else if (p['data_type'] != 'STRING') {
          final n = double.tryParse(value);
          if (n == null || !n.isFinite) throw Exception('请输入有限数字');
          data = n;
        }
        result = await widget.api.request(
          'POST',
          '/api/v1/points/${p['id']}/sample',
          body: {'value': data},
        );
      }
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(stateLabel(result['state']?.toString() ?? 'accepted')),
            content: SelectableText((result['message'] ?? '手工值已提交').toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
      await _poll();
    });
  }

  Future<void> pointMenu(int index, Offset location, List<Json> rows) async {
    final p = rows[index];
    setState(() => selectedID = p['id'].toString());
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        location.dx,
        location.dy,
        location.dx,
        location.dy,
      ),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('编辑点位')),
        if (p['writable'] == true || p['source_type'] == 'manual')
          const PopupMenuItem(value: 'write', child: Text('输入／下设数据')),
        const PopupMenuItem(value: 'history', child: Text('查询点位历史')),
        const PopupMenuItem(value: 'delete', child: Text('删除配置')),
      ],
    );
    if (!mounted) return;
    if (action == 'edit') await add(existing: p);
    if (action == 'write') await writePoint(p);
    if (action == 'history') {
      setState(() {
        historyPoint = p['id'].toString();
        page = 4;
      });
      await queryHistory(reset: true);
    }
    if (action == 'delete') {
      await act(() async {
        await widget.api.request('DELETE', '/api/v1/points/${p['id']}');
        setState(() => draft = true);
        await _load();
      });
    }
  }

  Json filterQuery({bool includePage = true}) {
    final q = <String, dynamic>{
      if (station.isNotEmpty) 'station': station,
      if (historyPoint.isNotEmpty) 'point_id': historyPoint,
      if (quality.isNotEmpty) 'quality': quality,
      if (min.text.trim().isNotEmpty) 'min': min.text.trim(),
      if (max.text.trim().isNotEmpty) 'max': max.text.trim(),
    };
    for (final entry in {'from': from, 'to': to}.entries) {
      if (entry.value.text.trim().isNotEmpty) {
        final date = DateTime.tryParse(entry.value.text.trim());
        if (date == null) throw Exception('请输入 ISO 时间');
        q[entry.key] = date.toUtc().millisecondsSinceEpoch;
      }
    }
    if (boundary != 0) q['before'] = boundary;
    if (includePage) {
      q['offset'] = offset;
      q['limit'] = 1000;
    }
    return q;
  }

  Future<void> queryHistory({bool reset = false}) async => act(() async {
    if (reset) {
      offset = 0;
      boundary = 0;
    }
    final scope = station;
    final result = await widget.api.request(
      'GET',
      '/api/v1/history',
      query: filterQuery(),
    );
    if (!mounted || scope != station) return;
    setState(() {
      history = objects(result['items']);
      stats = Map<String, dynamic>.from(result['stats'] as Map);
      boundary = (result['boundary'] as num).toInt();
    });
  });
  Future<void> export(String format) async => act(() async {
    final scope = station;
    final frozen = filterQuery();
    final refreshed = await widget.api.request(
      'GET',
      '/api/v1/history',
      query: frozen,
    );
    if (!mounted) return;
    if (scope == station) {
      setState(() {
        history = objects(refreshed['items']);
        stats = Map<String, dynamic>.from(refreshed['stats'] as Map);
        boundary = (refreshed['boundary'] as num).toInt();
      });
    }
    final q = Map<String, dynamic>.of(frozen)
      ..remove('offset')
      ..remove('limit');
    q['before'] = refreshed['boundary'];
    q['format'] = format;
    await widget.api.request('POST', '/api/v1/export', query: q);
    await _load();
  }, success: '报表任务已排队');
  Future<void> upload() async => act(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '数据文件', extensions: ['xlsx', 'csv']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 8 * 1024 * 1024) {
      throw Exception('文件上限 8 MiB，请缩小数据范围');
    }
    final result = await widget.api.upload(file.name, await file.readAsBytes());
    if (!mounted) return;
    final imported = await importEditor(context, widget.api, result);
    if (imported is Map && mounted) {
      setState(() {
        historyPoint = imported['point_id'].toString();
        saveSession();
        station = imported['station'].toString();
        restoreSession(sessions.putIfAbsent(station, StationSession.new));
        historyPoint = imported['point_id'].toString();
        contextRevision++;
        page = 4;
        boundary = 0;
        offset = 0;
      });
      await _load();
      final data = await widget.api.request(
        'GET',
        '/api/v1/history',
        query: filterQuery(),
      );
      if (mounted) {
        setState(() {
          history = objects(data['items']);
          stats = Map<String, dynamic>.from(data['stats'] as Map);
          boundary = (data['boundary'] as num).toInt();
        });
      }
    }
  });
  Future<void> commandPalette() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('切换工作区'),
        children: List.generate(
          pages.length,
          (i) => SimpleDialogOption(
            onPressed: () => Navigator.pop(context, i),
            child: Row(
              children: [
                Icon(pageIcons[i], size: 18),
                const SizedBox(width: 12),
                Text(pages[i]),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice != null && mounted) setState(() => page = choice);
  }

  Widget split(ValueChanged<double> onDelta, VoidCallback onEnd) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
      onHorizontalDragEnd: (_) => onEnd(),
      child: const SizedBox(width: 4, child: VerticalDivider(width: 1)),
    ),
  );
  void navigate(int destination) {
    setState(() => page = destination);
  }

  void selectPoint(Json point) {
    setState(() {
      selectedID = point['id'].toString();
      inspectorVisible = true;
    });
  }

  Widget navigationButton(int index, String title) {
    final active = index == 0 ? [0, 2, 3, 5].contains(page) : page == index;
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 2,
            color: active ? WorkbenchColors.accent : Colors.transparent,
          ),
        ),
      ),
      child: TextButton.icon(
        key: Key('nav-$index'),
        onPressed: () => navigate(index),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 28),
          foregroundColor: active
              ? WorkbenchColors.accent
              : WorkbenchColors.muted,
          shape: const RoundedRectangleBorder(),
        ),
        icon: Icon(pageIcons[index], size: 14),
        label: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget topMenu(String title, Map<String, VoidCallback> entries) =>
      PopupMenuButton<String>(
        tooltip: title,
        padding: EdgeInsets.zero,
        onSelected: (value) => entries[value]?.call(),
        itemBuilder: (_) => entries.keys
            .map(
              (label) => PopupMenuItem(
                value: label,
                height: 30,
                child: Text(label, style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Center(
            child: Text(title, style: const TextStyle(fontSize: 11)),
          ),
        ),
      );

  Widget documentTab(String scope) {
    final active = station == scope;
    return Container(
      height: 30,
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 190),
      decoration: BoxDecoration(
        color: active ? Colors.white : const Color(0xffeef2f8),
        border: Border(
          top: BorderSide(
            width: 2,
            color: active ? WorkbenchColors.accent : Colors.transparent,
          ),
          right: const BorderSide(color: WorkbenchColors.line),
        ),
      ),
      child: InkWell(
        onTap: () => switchStation(scope),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                scope.isEmpty ? Icons.public : Icons.folder_outlined,
                size: 14,
                color: active ? WorkbenchColors.accent : WorkbenchColors.muted,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  scope.isEmpty ? '公共总调度' : scope,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (scope.isNotEmpty) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 20,
                  height: 22,
                  child: IconButton(
                    tooltip: '关闭工作区标签',
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      if (station == scope) switchStation('');
                      setState(() => openTabs.remove(scope));
                    },
                    icon: const Icon(Icons.close, size: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget activityRail() {
    Widget item(
      IconData icon,
      String label,
      VoidCallback action, {
      bool active = false,
    }) => Container(
      width: 34,
      height: 34,
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: active ? WorkbenchColors.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(3),
      ),
      child: IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(
          icon,
          size: 19,
          color: active ? WorkbenchColors.accent : WorkbenchColors.muted,
        ),
      ),
    );
    return Container(
      width: 40,
      decoration: const BoxDecoration(
        color: Color(0xfff2f4f8),
        border: Border(right: BorderSide(color: WorkbenchColors.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          item(
            Icons.account_tree_outlined,
            '资源管理器',
            () => setState(() => navigatorVisible = !navigatorVisible),
            active: navigatorVisible,
          ),
          item(
            Icons.view_quilt_outlined,
            '站点总览',
            () => navigate(6),
            active: page == 6 && !navigatorVisible,
          ),
          item(Icons.compare_arrows, '跨站比较', () {
            switchStation('');
            navigate(1);
          }, active: page == 1),
          item(Icons.router_outlined, '采集来源', () {
            switchStation('');
            navigate(5);
          }, active: page == 5),
          const Spacer(),
          item(Icons.keyboard_outlined, '快速切换 · Ctrl+P', commandPalette),
          item(
            Icons.science_outlined,
            runtime['demo'] == true ? '暂停模拟采集' : '启动模拟工程',
            () {
              if (online && !busy) demo();
            },
          ),
          const SizedBox(height: 5),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            commandPalette,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): add,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): apply,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          navigate(0);
          searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyP, meta: true):
            commandPalette,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: const BoxDecoration(
                  color: WorkbenchColors.chrome,
                  border: Border(
                    bottom: BorderSide(color: WorkbenchColors.line),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.hub_outlined,
                      size: 17,
                      color: WorkbenchColors.accent,
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      'Universal HMI',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .35,
                      ),
                    ),
                    const SizedBox(width: 10),
                    topMenu('项目', {
                      '添加点位': add,
                      '应用配置': apply,
                      '导入 Excel / CSV': upload,
                      runtime['demo'] == true ? '暂停模拟采集' : '启动模拟工程': demo,
                    }),
                    topMenu('编辑', {
                      '搜索变量': () {
                        navigate(0);
                        searchFocus.requestFocus();
                      },
                      if (current != null)
                        '编辑当前变量': () => add(existing: current),
                    }),
                    topMenu('查看', {
                      '总览': () => navigate(6),
                      '历史报表': () => navigate(4),
                      '历史曲线': () => navigate(7),
                      '设置': () => navigate(0),
                    }),
                    const Spacer(),
                    SizedBox(
                      width: 250,
                      height: 22,
                      child: Material(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          side: const BorderSide(color: WorkbenchColors.line),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: InkWell(
                          onTap: commandPalette,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.search,
                                  size: 13,
                                  color: WorkbenchColors.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    station.isEmpty ? '搜索工作区' : station,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                                const Text(
                                  'Ctrl+P',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: WorkbenchColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 25,
                      child: IconButton(
                        tooltip: '刷新运行工作台',
                        onPressed: busy ? null : _load,
                        icon: const Icon(Icons.refresh, size: 14),
                      ),
                    ),
                    SizedBox(
                      width: 25,
                      child: IconButton(
                        tooltip: '显示／隐藏资源树',
                        onPressed: () => setState(
                          () => navigatorVisible = !navigatorVisible,
                        ),
                        icon: const Icon(Icons.view_sidebar_outlined, size: 14),
                      ),
                    ),
                    SizedBox(
                      width: 25,
                      child: IconButton(
                        tooltip: '显示／隐藏变量详情',
                        onPressed: () => setState(
                          () => inspectorVisible = !inspectorVisible,
                        ),
                        icon: const Icon(
                          Icons.vertical_split_outlined,
                          size: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final showInspector =
                        box.maxWidth >= 940 &&
                        current != null &&
                        inspectorVisible &&
                        [0, 1, 6, 8].contains(page);
                    return Row(
                      children: [
                        activityRail(),
                        if (navigatorVisible && box.maxWidth >= 780) ...[
                          SizedBox(width: treeWidth - 4, child: tree()),
                          split(
                            (d) => setState(
                              () => treeWidth = (treeWidth + d).clamp(176, 320),
                            ),
                            _persist,
                          ),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                height: 30,
                                decoration: const BoxDecoration(
                                  color: Color(0xffeef2f8),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: WorkbenchColors.line,
                                    ),
                                  ),
                                ),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      documentTab(''),
                                      for (final scope in openTabs)
                                        documentTab(scope),
                                    ],
                                  ),
                                ),
                              ),
                              Container(
                                height: 30,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  border: Border(
                                    bottom: BorderSide(
                                      color: WorkbenchColors.line,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: [
                                            navigationButton(6, '运行总览'),
                                            navigationButton(8, '变量监视'),
                                            if (station.isEmpty)
                                              navigationButton(1, '跨站比较'),
                                            navigationButton(4, '历史报表'),
                                            navigationButton(7, '历史曲线'),
                                            navigationButton(0, '设置'),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (draft)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        child: TextButton(
                                          onPressed: online && !busy
                                              ? apply
                                              : null,
                                          child: const Text(
                                            '有未应用配置',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: WorkbenchColors.amber,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if ([0, 2, 3, 5].contains(page))
                                Container(
                                  height: 29,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  decoration: const BoxDecoration(
                                    color: WorkbenchColors.chrome,
                                    border: Border(
                                      bottom: BorderSide(
                                        color: WorkbenchColors.line,
                                      ),
                                    ),
                                  ),
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        for (final entry in {
                                          0: '变量设置',
                                          2: '条件事件',
                                          3: '独立存储',
                                          if (station.isEmpty) 5: '采集来源',
                                        }.entries)
                                          TextButton(
                                            onPressed: () =>
                                                navigate(entry.key),
                                            style: TextButton.styleFrom(
                                              foregroundColor: page == entry.key
                                                  ? c.primary
                                                  : c.onSurfaceVariant,
                                            ),
                                            child: Text(
                                              entry.value,
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (error != null)
                                Container(
                                  color: c.errorContainer,
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    3,
                                    4,
                                    3,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline,
                                        size: 14,
                                        color: c.error,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          error!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: c.error,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '关闭提示',
                                        onPressed: () =>
                                            setState(() => error = null),
                                        icon: const Icon(Icons.close, size: 13),
                                      ),
                                    ],
                                  ),
                                ),
                              if (busy)
                                const LinearProgressIndicator(minHeight: 2),
                              Expanded(
                                child: PageStorage(
                                  bucket: buckets.putIfAbsent(
                                    station,
                                    PageStorageBucket.new,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      page == 6 || page == 8 ? 0 : 8,
                                    ),
                                    child: switch (page) {
                                      0 => pointWorkspace(),
                                      1 => trendWorkspace(),
                                      2 => eventWorkspace(),
                                      3 => historyWorkspace(),
                                      4 => reportWorkspace(),
                                      5 => sourceWorkspace(),
                                      7 => historicalCurves(),
                                      8 => stationMonitor(),
                                      _ => overviewWorkspace(),
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (showInspector) ...[
                          split(
                            (d) => setState(
                              () => inspectorWidth = (inspectorWidth - d).clamp(
                                258,
                                390,
                              ),
                            ),
                            _persist,
                          ),
                          SizedBox(width: inspectorWidth, child: inspector()),
                        ],
                      ],
                    );
                  },
                ),
              ),
              Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: WorkbenchColors.chrome,
                  border: Border(top: BorderSide(color: WorkbenchColors.line)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 6,
                      color: online ? const Color(0xff009c85) : c.error,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      online ? '后端已连接' : '后端离线',
                      style: const TextStyle(fontSize: 9),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      station.isEmpty ? '公共总调度' : station,
                      key: const Key('active-station'),
                      style: const TextStyle(fontSize: 9),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${points.length} 变量 · ${stationNames.length} 站点 · ${sources.length} 来源',
                      style: const TextStyle(
                        fontSize: 9,
                        color: WorkbenchColors.muted,
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: '来源、接收和历史时间按本机时区显示；原始带时区时间不变',
                      child: Text(
                        '时间 ${utcOffsetLabel(DateTime.now().timeZoneOffset)}',
                        key: const Key('display-timezone'),
                        style: const TextStyle(
                          fontSize: 9,
                          color: WorkbenchColors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if ((runtime['storage_error'] ?? '').toString().isNotEmpty)
                      Text(
                        '存储错误  ',
                        style: TextStyle(color: c.error, fontSize: 9),
                      ),
                    if ((runtime['dropped'] as num? ?? 0) > 0)
                      Text(
                        '丢弃 ${runtime['dropped']}  ',
                        style: TextStyle(color: c.error, fontSize: 9),
                      ),
                    Text(
                      policy['enabled'] == true ? '独立存储运行中' : '独立存储未启动',
                      style: const TextStyle(
                        fontSize: 9,
                        color: WorkbenchColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget tree() {
    final c = Theme.of(context).colorScheme;
    return Container(
      decoration: const BoxDecoration(
        color: WorkbenchColors.chrome,
        border: Border(right: BorderSide(color: WorkbenchColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  const Text(
                    '资源管理器',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: WorkbenchColors.muted,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: IconButton(
                      tooltip: '添加点位',
                      padding: EdgeInsets.zero,
                      onPressed: online ? add : null,
                      icon: const Icon(Icons.add, size: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 28,
            child: InkWell(
              key: const Key('station-global'),
              onTap: () => switchStation(''),
              child: Padding(
                padding: const EdgeInsets.only(left: 15),
                child: Row(
                  children: [
                    Icon(
                      Icons.public,
                      size: 14,
                      color: station.isEmpty ? c.primary : c.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '公共总调度',
                      style: TextStyle(
                        fontSize: 11,
                        color: station.isEmpty ? c.primary : c.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                const Text(
                  '站点项目',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: WorkbenchColors.muted,
                  ),
                ),
                const Spacer(),
                Text(
                  '${stationNames.length}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: WorkbenchColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const Key('station-tree-scroll'),
              itemCount: stationNames.length,
              itemBuilder: (context, i) {
                final name = stationNames[i], active = station == name;
                return Container(
                  decoration: BoxDecoration(
                    color: active
                        ? WorkbenchColors.selection
                        : Colors.transparent,
                  ),
                  foregroundDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        width: 2,
                        color: active ? c.primary : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 28,
                        child: InkWell(
                          key: Key('station-$name'),
                          onTap: () => switchStation(name),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_outlined,
                                  size: 14,
                                  color: active
                                      ? c.primary
                                      : c.onSurfaceVariant,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${stationPoints[name]?.length ?? 0}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: WorkbenchColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (active)
                        for (final entry in {
                          6: '运行总览',
                          8: '变量监视',
                          4: '历史报表',
                          7: '历史曲线',
                          0: '设置',
                        }.entries)
                          SizedBox(
                            height: 28,
                            child: InkWell(
                              onTap: () => navigate(entry.key),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 36),
                                child: Row(
                                  children: [
                                    Icon(
                                      pageIcons[entry.key],
                                      size: 14,
                                      color: page == entry.key
                                          ? c.primary
                                          : c.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      entry.value,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: page == entry.key
                                            ? c.primary
                                            : c.onSurface,
                                        fontWeight: page == entry.key
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                );
              },
            ),
          ),
          const Divider(),
          const SizedBox(
            height: 24,
            child: Padding(
              padding: EdgeInsets.only(left: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 12,
                    color: WorkbenchColors.muted,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '本地工作空间',
                    style: TextStyle(
                      fontSize: 10,
                      color: WorkbenchColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> chooseWatched({bool forTrend = false}) async {
    final available = scopedPoints;
    final chosen = Set<String>.of(forTrend ? selected : watched);
    final controller = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final term = controller.text.toLowerCase();
          final rows = term.isEmpty
              ? available
              : available
                    .where(
                      (p) => '${p['name']} ${p['station']} ${p['unit']}'
                          .toLowerCase()
                          .contains(term),
                    )
                    .toList();
          return AlertDialog(
            title: Text(forTrend ? '选择趋势变量' : '选择关注变量'),
            content: SizedBox(
              width: 540,
              height: 390,
              child: Column(
                children: [
                  TextField(
                    key: const Key('watch-search'),
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索变量、站点或单位',
                      prefixIcon: Icon(Icons.search, size: 16),
                    ),
                    onChanged: (_) => update(() {}),
                  ),
                  SizedBox(
                    height: 28,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '已选择 ${chosen.length} / 6',
                        style: const TextStyle(
                          fontSize: 11,
                          color: WorkbenchColors.muted,
                        ),
                      ),
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemExtent: 32,
                      itemBuilder: (context, i) {
                        final p = rows[i], id = p['id'].toString();
                        return CheckboxListTile(
                          key: Key('watch-choice-$id'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: chosen.contains(id),
                          onChanged: (value) => update(() {
                            if (value == true && chosen.length < 6) {
                              chosen.add(id);
                            } else if (value == false) {
                              chosen.remove(id);
                            }
                          }),
                          title: Text(
                            '${p['station']} / ${p['name']}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          secondary: Text(
                            '${p['unit'] ?? ''}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: WorkbenchColors.muted,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('watch-save'),
                onPressed: () => Navigator.pop(context, chosen),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (result != null && mounted) {
      setState(() {
        if (forTrend) {
          selected
            ..clear()
            ..addAll(result);
          trendVisible = true;
          acceptRuntime(runtime, connectionConfirmed: false);
        } else {
          watched
            ..clear()
            ..addAll(result);
        }
      });
    }
  }

  List<Json> get operationalRows {
    final rows = visible;
    return rows.where((p) {
      final r = live[p['id']];
      final inView = switch (operationalView) {
        'watched' => watched.contains(p['id']),
        'attention' => !online || r == null || r['quality'] != 'good',
        'writable' => p['writable'] == true && p['rw_mode'] != 'R',
        _ => true,
      };
      return inView && (sourceFilter.isEmpty || sourceFilter == pointSource(p));
    }).toList();
  }

  Widget watchStrip() {
    final rows = watched.map((id) => pointIndex[id]).whereType<Json>().toList();
    if (rows.isEmpty) {
      return Container(
        height: 35,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.star_border,
              size: 14,
              color: WorkbenchColors.muted,
            ),
            const SizedBox(width: 7),
            const Text(
              '未配置关注变量',
              style: TextStyle(fontSize: 11, color: WorkbenchColors.muted),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('choose-watched'),
              onPressed: chooseWatched,
              child: const Text('选择关注变量', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 54,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
      ),
      child: Row(
        children: [
          for (final p in rows)
            Expanded(
              child: InkWell(
                onTap: () => selectPoint(p),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 5, 8, 4),
                  decoration: const BoxDecoration(
                    border: Border(
                      right: BorderSide(color: WorkbenchColors.line),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 5,
                            color: qualityColor(
                              online
                                  ? (live[p['id']]?['quality'] ?? 'missing')
                                        .toString()
                                  : 'stale',
                              Theme.of(context).colorScheme,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              p['name'].toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: FittedBox(
                                alignment: Alignment.centerLeft,
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  number(live[p['id']]?['value']),
                                  style: numericStyle.copyWith(fontSize: 18),
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${p['unit'] ?? ''}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: WorkbenchColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 27,
            child: IconButton(
              key: const Key('choose-watched'),
              tooltip: '编辑关注变量',
              onPressed: chooseWatched,
              icon: const Icon(Icons.edit_outlined, size: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget overviewTools() {
    final sourceIDs = scopedPoints.map((p) => pointSource(p)).toSet().toList()
      ..sort();
    return Container(
      width: double.infinity,
      height: 32,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in {
              'all': '全部 ${scopedPoints.length}',
              'watched': '关注 ${watched.length}',
              'attention': '异常',
              'writable': '可写',
            }.entries)
              Container(
                height: 32,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: operationalView == entry.key
                          ? WorkbenchColors.accent
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: TextButton(
                  key: Key('operational-${entry.key}'),
                  onPressed: () => setState(() {
                    operationalView = entry.key;
                    tableScroll = 0;
                    matrixScroll = 0;
                  }),
                  style: TextButton.styleFrom(
                    foregroundColor: operationalView == entry.key
                        ? WorkbenchColors.accent
                        : WorkbenchColors.muted,
                  ),
                  child: Text(
                    entry.value,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            SizedBox(
              width: 165,
              height: 28,
              child: TextField(
                key: const Key('point-search'),
                controller: search,
                focusNode: searchFocus,
                decoration: const InputDecoration(
                  hintText: '筛选变量',
                  prefixIcon: Icon(Icons.search, size: 14),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
                onChanged: (v) => setState(() {
                  query = v;
                  tableScroll = 0;
                  matrixScroll = 0;
                }),
              ),
            ),
            const SizedBox(width: 6),
            PopupMenuButton<String>(
              tooltip: '按采集来源筛选',
              onSelected: (v) => setState(() {
                sourceFilter = v;
                tableScroll = 0;
                matrixScroll = 0;
              }),
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('全部来源')),
                ...sourceIDs.map(
                  (id) => PopupMenuItem(value: id, child: Text(id)),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.filter_alt_outlined,
                      size: 13,
                      color: WorkbenchColors.muted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sourceFilter.isEmpty ? '全部来源' : sourceFilter,
                      style: const TextStyle(
                        fontSize: 10,
                        color: WorkbenchColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16, child: VerticalDivider(width: 12)),
            for (final layout in ['matrix', 'table'])
              IconButton(
                key: Key('monitor-layout-$layout'),
                tooltip: layout == 'matrix' ? '矩阵视图' : '表格视图',
                onPressed: () => setState(() => monitorLayout = layout),
                color: monitorLayout == layout
                    ? WorkbenchColors.accent
                    : WorkbenchColors.muted,
                icon: Icon(
                  layout == 'matrix'
                      ? Icons.grid_view
                      : Icons.table_rows_outlined,
                  size: 16,
                ),
              ),
            if (monitorLayout == 'matrix')
              PopupMenuButton<bool>(
                key: const Key('matrix-density-control'),
                tooltip: '矩阵密度',
                onSelected: (value) => setState(() {
                  matrixCompact = value;
                  matrixScroll = 0;
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    key: Key('matrix-density-compact'),
                    value: true,
                    child: Text('紧凑'),
                  ),
                  const PopupMenuItem(
                    key: Key('matrix-density-comfortable'),
                    value: false,
                    child: Text('舒展'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Text(
                        matrixCompact ? '紧凑' : '舒展',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
              ),
            IconButton(
              tooltip: '选择趋势变量',
              onPressed: () => chooseWatched(forTrend: true),
              icon: const Icon(Icons.show_chart, size: 15),
            ),
            IconButton(
              tooltip: trendVisible ? '收起实时曲线' : '展开实时曲线',
              onPressed: () => setState(() => trendVisible = !trendVisible),
              icon: Icon(
                trendVisible ? Icons.vertical_align_bottom : Icons.expand_less,
                size: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget trendDock(double availableHeight) {
    final maxHeight = math.max(135.0, availableHeight - 200);
    final height = trendHeight.clamp(135.0, maxHeight);
    return SizedBox(
      height: trendVisible ? height : 28,
      child: Column(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => setState(
                () => trendHeight = (trendHeight - d.delta.dy).clamp(
                  135.0,
                  maxHeight,
                ),
              ),
              child: const SizedBox(
                height: 4,
                width: double.infinity,
                child: Divider(color: Color(0xff9db5f5), height: 1),
              ),
            ),
          ),
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              color: WorkbenchColors.chrome,
              border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
            ),
            child: Row(
              children: [
                const Text(
                  '实时曲线',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                const Text(
                  '3 min',
                  style: TextStyle(fontSize: 10, color: WorkbenchColors.muted),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => chooseWatched(forTrend: true),
                  child: const Text('+ 选择变量', style: TextStyle(fontSize: 10)),
                ),
                SizedBox(
                  width: 22,
                  child: IconButton(
                    tooltip: trendVisible ? '收起曲线' : '展开曲线',
                    padding: EdgeInsets.zero,
                    onPressed: () =>
                        setState(() => trendVisible = !trendVisible),
                    icon: Icon(
                      trendVisible ? Icons.close : Icons.expand_less,
                      size: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (trendVisible)
            Expanded(
              child: Trend(
                key: PageStorageKey('overview-trend-$station'),
                rows: trendRows,
                names: {
                  for (final id
                      in buffer.map((r) => r['point_id'].toString()).toSet())
                    id: '${pointIndex[id]?['name'] ?? id} (${pointIndex[id]?['unit'] ?? ''})',
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget stationMonitor() => LayoutBuilder(
    builder: (context, box) {
      final metric = station.isEmpty
          ? stationMetrics.values.fold<Json>(
              {},
              (latest, value) =>
                  (value['last_ms'] as int? ?? 0) >
                      (latest['last_ms'] as int? ?? 0)
                  ? value
                  : latest,
            )
          : stationMetrics[station] ?? {};
      final good = !online
          ? 0
          : station.isEmpty
          ? goodCounts.values.fold(0, (a, b) => a + b)
          : goodCounts[station] ?? 0;
      return Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
            ),
            child: Row(
              children: [
                Text(
                  station.isEmpty ? '全部站点' : station,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Color(0xff17212b),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$good / ${scopedPoints.length} 正常',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff56616d),
                  ),
                ),
                const SizedBox(width: 12),
                if (scopedPoints.length > good)
                  Text(
                    '${scopedPoints.length - good} 需关注',
                    style: const TextStyle(
                      fontSize: 12,
                      color: WorkbenchColors.amber,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '最近接收 ${clock(metric['last_time'])}',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff56616d),
                    ),
                  ),
                ),
                if (watched.isEmpty)
                  IconButton(
                    key: const Key('choose-watched'),
                    tooltip: '选择关注变量',
                    onPressed: chooseWatched,
                    icon: const Icon(Icons.star_border, size: 17),
                  ),
              ],
            ),
          ),
          if (watched.isNotEmpty) watchStrip(),
          overviewTools(),
          Expanded(
            child: monitorLayout == 'matrix'
                ? pointMatrix()
                : pointTable(operations: true),
          ),
          trendDock(box.maxHeight),
        ],
      );
    },
  );

  Widget dispatchOverview() {
    final c = Theme.of(context).colorScheme;
    final ordered = stationNames.toList()
      ..sort((a, b) {
        final attentionA =
            (stationPoints[a]?.length ?? 0) - (online ? goodCounts[a] ?? 0 : 0);
        final attentionB =
            (stationPoints[b]?.length ?? 0) - (online ? goodCounts[b] ?? 0 : 0);
        final byAttention = attentionB.compareTo(attentionA);
        return byAttention == 0 ? a.compareTo(b) : byAttention;
      });
    return Column(
      key: const Key('global-overview'),
      children: [
        Container(
          height: 31,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: WorkbenchColors.chrome,
            border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
          ),
          child: Row(
            children: [
              const Icon(Icons.public, size: 14, color: WorkbenchColors.muted),
              const SizedBox(width: 7),
              Text(
                '${stationNames.length} 站点总调度',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 14),
              const Text(
                '异常优先',
                style: TextStyle(fontSize: 10, color: WorkbenchColors.muted),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => navigate(1),
                child: const Text('跨站趋势比较', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: () => navigate(0),
                child: const Text('管理全部变量', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: stationNames.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('尚未配置站点', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: online ? demo : null,
                        icon: const Icon(Icons.science_outlined, size: 15),
                        label: const Text('启动模拟工程'),
                      ),
                    ],
                  ),
                )
              : DenseTable(
                  key: const ValueKey('dispatch-station-table'),
                  headers: const [
                    '站点',
                    '变量数',
                    '正常',
                    '异常 / 无数据',
                    '陈旧',
                    '最近接收',
                    '未决命令',
                  ],
                  initialWidths: const [145, 86, 80, 105, 80, 178, 88],
                  numericColumns: const {1, 2, 3, 4, 6},
                  rowCount: ordered.length,
                  rowKey: (i) => Key('dispatch-row-${ordered[i]}'),
                  rowBuilder: (i) {
                    final name = ordered[i],
                        total = stationPoints[name]?.length ?? 0,
                        metric = stationMetrics[name] ?? {};
                    final good = online ? goodCounts[name] ?? 0 : 0,
                        stale = online ? metric['stale'] as int? ?? 0 : total;
                    final pending = commandResults.values
                        .where(
                          (r) =>
                              pointIndex[r['point_id']]?['station'] == name &&
                              [
                                'accepted',
                                'sent',
                                'acknowledged',
                                'unknown',
                              ].contains(r['state']) &&
                              r['ack_state'] != 'unsupported' &&
                              r['readback_state'] != 'unconfirmed',
                        )
                        .length;
                    return [
                      name,
                      '$total',
                      '$good',
                      '${math.max(0, total - good - stale)}',
                      '$stale',
                      clock(metric['last_time']),
                      '$pending',
                    ];
                  },
                  onSelect: (i) => switchStation(ordered[i]),
                ),
        ),
        Container(
          height: 25,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: c.surfaceContainerLow,
            border: Border(top: BorderSide(color: c.outlineVariant)),
          ),
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '点击站点进入独立工作区 · 写入结果在目标变量中逐项核对',
              style: TextStyle(fontSize: 10, color: WorkbenchColors.muted),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> loadEvents() async {
    final scope = station;
    try {
      final result = await widget.api.request('GET', '/api/v1/executions');
      if (!mounted || scope != station) return;
      setState(() {
        logs = snapshotObjects(
          result['items'],
        ).where((entry) => scope.isEmpty || entry['station'] == scope).toList();
        eventsLoaded = true;
        eventsError = null;
      });
    } catch (_) {
      if (mounted && scope == station) {
        setState(() {
          eventsLoaded = true;
          eventsError = '事件记录暂不可用';
        });
      }
    }
  }

  void openAttention() => setState(() {
    operationalView = 'attention';
    query = '';
    search.clear();
    sourceFilter = '';
    tableScroll = 0;
    page = 8;
  });

  Widget dashboardWatchTile(Json p, List<Json> rows) {
    final r = live[p['id']] ?? <String, dynamic>{};
    final q = online ? (r['quality'] ?? 'missing').toString() : 'stale';
    return InkWell(
      key: Key('watched-variable-${p['id']}'),
      onTap: () => selectPoint(p),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: WorkbenchColors.line),
            bottom: BorderSide(color: WorkbenchColors.line),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    p['name'].toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
                Text(
                  qualityLabel(q),
                  style: TextStyle(
                    fontSize: 9,
                    color: qualityColor(q, Theme.of(context).colorScheme),
                  ),
                ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    number(r['value']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: numericStyle.copyWith(fontSize: 18),
                  ),
                ),
                Text(
                  '${p['unit'] ?? ''}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: WorkbenchColors.muted,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SampleSparkline(rows: rows),
              ),
            ),
            EngineeringRange(
              value: r['value'],
              minimum: p['min'],
              maximum: p['max'],
            ),
          ],
        ),
      ),
    );
  }

  Widget dashboardWatchArea(
    List<Json> watches,
    Map<String, List<Json>> curves,
    Map<String, String> sourceNames,
  ) {
    if (watches.isEmpty) {
      return OperationalPanel(
        title: '关注趋势与统计',
        trailing: TextButton(
          key: const Key('choose-watched'),
          onPressed: chooseWatched,
          child: const Text('+ 选择关注变量', style: TextStyle(fontSize: 10)),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '未配置关注变量',
                style: TextStyle(fontSize: 11, color: WorkbenchColors.muted),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: chooseWatched,
                child: const Text(
                  '选择需要持续观察的变量',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final groups = <String, List<Json>>{};
    for (final p in watches) {
      final label = watchGrouping == 'unit'
          ? ((p['unit'] ?? '').toString().isEmpty
                ? '无单位'
                : p['unit'].toString())
          : sourceNames[pointSource(p)] ?? sourceTypeLabel(pointSource(p));
      groups.putIfAbsent(label, () => []).add(p);
    }
    final units = watches
        .map((p) => (p['unit'] ?? '').toString())
        .toSet()
        .toList();
    final unit = units.contains(dashboardUnit) ? dashboardUnit : units.first;
    final chartPoints = watches
        .where((p) => (p['unit'] ?? '').toString() == unit)
        .toList();
    final chartIDs = chartPoints.map((p) => p['id']).toSet();
    final chartRows = buffer
        .where((r) => chartIDs.contains(r['point_id']))
        .toList();
    final statistics = chartPoints.map((p) {
      final samples = (curves[p['id']] ?? const <Json>[])
          .where((r) => r['quality'] == 'good' && r['value'] is num)
          .toList();
      final values = samples
          .map((r) => (r['value'] as num).toDouble())
          .toList();
      return [
        p['name'].toString(),
        number(live[p['id']]?['value']),
        (p['unit'] ?? '').toString(),
        number(values.isEmpty ? null : values.reduce(math.min)),
        number(values.isEmpty ? null : values.reduce(math.max)),
        number(
          values.isEmpty
              ? null
              : values.reduce((a, b) => a + b) / values.length,
        ),
      ];
    }).toList();
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 700
            ? 3
            : box.maxWidth >= 450
            ? 2
            : 1;
        final desiredStripHeight = groups.values
            .fold<int>(
              0,
              (total, group) =>
                  total + 19 + (group.length / columns).ceil() * 92,
            )
            .toDouble();
        final stripHeight = math.min(
          desiredStripHeight,
          box.maxHeight < 430 ? 111.0 : 203.0,
        );
        final statisticsHeight = math.min(
          32.0 + statistics.length * 28,
          box.maxHeight < 430 ? 88.0 : 120.0,
        );
        return Column(
          children: [
            Container(
              height: 27,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: const BoxDecoration(
                color: WorkbenchColors.chrome,
                border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
              ),
              child: Row(
                children: [
                  const Text(
                    '关注变量',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: '关注分组方式',
                    onSelected: (v) => setState(() => watchGrouping = v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'source', child: Text('按来源分组')),
                      PopupMenuItem(value: 'unit', child: Text('按单位分组')),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          watchGrouping == 'unit' ? '按单位分组' : '按来源分组',
                          style: const TextStyle(
                            fontSize: 10,
                            color: WorkbenchColors.muted,
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_down,
                          size: 14,
                          color: WorkbenchColors.muted,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    key: const Key('choose-watched'),
                    onPressed: chooseWatched,
                    child: const Text('编辑关注变量', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: stripHeight,
              child: ListView(
                children: [
                  for (final group in groups.entries) ...[
                    Container(
                      height: 19,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      color: const Color(0xfffafbfd),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${group.key} · ${group.value.length} 变量',
                          style: const TextStyle(
                            fontSize: 9,
                            color: WorkbenchColors.muted,
                          ),
                        ),
                      ),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: group.value.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 92,
                      ),
                      itemBuilder: (context, i) => dashboardWatchTile(
                        group.value[i],
                        curves[group.value[i]['id']] ?? const [],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              height: 25,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: const BoxDecoration(
                color: WorkbenchColors.chrome,
                border: Border(
                  top: BorderSide(color: WorkbenchColors.line),
                  bottom: BorderSide(color: WorkbenchColors.line),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    '关注趋势',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '最近 3 min · 按相同单位绘制',
                    style: TextStyle(fontSize: 9, color: WorkbenchColors.muted),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: '选择关注趋势单位',
                    onSelected: (v) => setState(() => dashboardUnit = v),
                    itemBuilder: (_) => units
                        .map(
                          (u) => PopupMenuItem(
                            value: u,
                            child: Text(u.isEmpty ? '无单位' : u),
                          ),
                        )
                        .toList(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          unit.isEmpty ? '无单位' : unit,
                          style: const TextStyle(
                            fontSize: 10,
                            color: WorkbenchColors.accent,
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_down,
                          size: 14,
                          color: WorkbenchColors.accent,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Trend(
                key: PageStorageKey('dashboard-trend-$station-$unit'),
                rows: chartRows,
                names: {
                  for (final p in chartPoints)
                    p['id'].toString(): p['name'].toString(),
                },
              ),
            ),
            Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: WorkbenchColors.chrome,
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '当前显示样本统计 · 仅有效质量',
                  style: TextStyle(fontSize: 9, color: WorkbenchColors.muted),
                ),
              ),
            ),
            SizedBox(
              height: statisticsHeight,
              child: DenseTable(
                key: const Key('overview-watch-statistics'),
                headers: const ['关注变量', '当前值', '单位', '最小', '最大', '均值'],
                initialWidths: const [210, 115, 70, 115, 115, 115],
                numericColumns: const {1, 3, 4, 5},
                rows: statistics,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget stationDashboard() {
    final c = Theme.of(context).colorScheme;
    final pointsBySource = <String, List<Json>>{};
    for (final p in scopedPoints) {
      pointsBySource.putIfAbsent(pointSource(p), () => []).add(p);
    }
    final sourceNames = {
      for (final s in sources) s['id'].toString(): s['name'].toString(),
    };
    final metric = stationMetrics[station] ?? {};
    final good = online ? goodCounts[station] ?? 0 : 0;
    final stale = online ? metric['stale'] as int? ?? 0 : scopedPoints.length;
    final bad = online ? metric['bad'] as int? ?? 0 : 0;
    final missing = math.max(0, scopedPoints.length - good - stale - bad);
    final issues = scopedPoints
        .where((p) => !online || live[p['id']]?['quality'] != 'good')
        .toList();
    final watches = watched
        .map((id) => pointIndex[id])
        .whereType<Json>()
        .toList();
    final curves = <String, List<Json>>{};
    for (final r in buffer) {
      if (watched.contains(r['point_id'])) {
        curves.putIfAbsent(r['point_id'].toString(), () => []).add(r);
      }
    }
    final expandedStatus = issues.isNotEmpty || logs.isNotEmpty;
    return Column(
      key: const Key('station-overview'),
      children: [
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: WorkbenchColors.chrome,
            border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
          ),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  station,
                  key: const Key('overview-scope'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${scopedPoints.length} 变量 · ${pointsBySource.length} 来源',
                key: const Key('overview-variable-count'),
                style: const TextStyle(
                  fontSize: 10,
                  color: WorkbenchColors.muted,
                ),
              ),
              const Spacer(),
              Text(
                '最近接收 ${clock(metric['last_time'])}',
                style: const TextStyle(
                  fontSize: 10,
                  color: WorkbenchColors.muted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: math.max(1, math.min(3, pointsBySource.length)) * 26,
          child: ListView.builder(
            itemCount: pointsBySource.length,
            itemExtent: 26,
            itemBuilder: (context, i) {
              final id = pointsBySource.keys.elementAt(i),
                  rows = pointsBySource[id]!;
              final healthy = rows
                  .where((p) => online && live[p['id']]?['quality'] == 'good')
                  .length;
              final state =
                  ((runtime['source_states'] as Map?)?[id] ??
                          (id == 'manual'
                              ? '本地输入'
                              : id == 'simulator'
                              ? runtime['demo'] == true
                                    ? '模拟运行'
                                    : '模拟已停止'
                              : '未连接'))
                      .toString();
              return InkWell(
                key: Key('overview-source-$id'),
                onTap: () => setState(() {
                  sourceFilter = id;
                  operationalView = 'all';
                  query = '';
                  search.clear();
                  tableScroll = 0;
                  page = 8;
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.router_outlined,
                        size: 13,
                        color: WorkbenchColors.muted,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${sourceNames[id] ?? sourceTypeLabel(id)} · $state',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                      Text(
                        '$healthy / ${rows.length} 正常',
                        style: numericStyle.copyWith(
                          fontSize: 10,
                          color: WorkbenchColors.muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        '业务分组未配置',
                        style: TextStyle(
                          fontSize: 9,
                          color: WorkbenchColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          height: 25,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: WorkbenchColors.line),
              bottom: BorderSide(color: WorkbenchColors.line),
            ),
          ),
          child: Row(
            children: [
              for (final entry in {
                '正常': good,
                '坏质量': bad,
                '陈旧': stale,
                '无数据': missing,
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: Text(
                    '${entry.key} ${entry.value}',
                    style: numericStyle.copyWith(
                      fontSize: 10,
                      color: entry.key == '正常' || entry.value == 0
                          ? WorkbenchColors.muted
                          : WorkbenchColors.amber,
                    ),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => navigate(8),
                child: const Text('变量监视', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ),
        Expanded(child: dashboardWatchArea(watches, curves, sourceNames)),
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: WorkbenchColors.chrome,
            border: Border(top: BorderSide(color: WorkbenchColors.line)),
          ),
          child: Row(
            children: [
              Text(
                '质量异常 · ${issues.length}',
                key: const Key('overview-issue-count'),
                style: TextStyle(
                  fontSize: 10,
                  color: issues.isEmpty
                      ? WorkbenchColors.muted
                      : WorkbenchColors.amber,
                ),
              ),
              TextButton(
                key: const Key('overview-attention-all'),
                onPressed: openAttention,
                child: const Text('查看全部', style: TextStyle(fontSize: 10)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  eventsError ??
                      (!eventsLoaded
                          ? '读取执行记录…'
                          : logs.isEmpty
                          ? '暂无事件执行记录'
                          : '${logs.length} 条最近执行记录'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: WorkbenchColors.muted,
                  ),
                ),
              ),
              Text(
                policy['enabled'] == true ? '存储运行中' : '存储未启动',
                style: const TextStyle(
                  fontSize: 9,
                  color: WorkbenchColors.muted,
                ),
              ),
              TextButton(
                onPressed: () => navigate(2),
                child: const Text('事件管理', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ),
        if (expandedStatus)
          SizedBox(
            height: math.min(
              136.0,
              28.0 *
                  math.max(
                    math.min(4, issues.length),
                    math.min(4, logs.length),
                  ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: math.min(8, issues.length),
                    itemExtent: 28,
                    itemBuilder: (context, i) {
                      final p = issues[i],
                          q = online
                              ? (live[p['id']]?['quality'] ?? 'missing')
                                    .toString()
                              : 'stale';
                      return InkWell(
                        key: Key('overview-issue-${p['id']}'),
                        onTap: () => selectPoint(p),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 13,
                                color: qualityColor(q, c),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  p['name'].toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                              Text(
                                qualityLabel(q),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: WorkbenchColors.amber,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: math.min(8, logs.length),
                    itemExtent: 28,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${logs[i]['name'] ?? logs[i]['type']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                          Text(
                            clock(logs[i]['at']),
                            style: const TextStyle(
                              fontSize: 9,
                              color: WorkbenchColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget overviewWorkspace() =>
      station.isEmpty ? dispatchOverview() : stationDashboard();

  Widget historyStatistics() {
    final rows = summarizeHistoryPage(history);
    return DenseTable(
      key: ValueKey('history-statistics-$station'),
      headers: const ['站点 / 变量', '单位', '有效 / 样本', '最小', '最大', '均值', '最新有效值'],
      initialWidths: const [215, 65, 100, 105, 105, 105, 120],
      numericColumns: const {2, 3, 4, 5, 6},
      rowCount: rows.length,
      rowBuilder: (i) {
        final r = rows[i];
        return [
          '${r['station']} / ${r['name']}',
          '${r['unit'] ?? ''}',
          '${r['valid']} / ${r['count']}',
          number(r['min']),
          number(r['max']),
          number(r['mean']),
          number(r['latest']),
        ];
      },
    );
  }

  Widget historicalCurves() => Column(
    children: [
      filters(),
      const SizedBox(height: 5),
      summary(),
      Container(
        height: 27,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const Text(
              '历史曲线',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '当前第 ${offset ~/ 1000 + 1} 页 · ${history.length} 样本 · 最多显示 6 条曲线',
              style: const TextStyle(
                fontSize: 10,
                color: WorkbenchColors.muted,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        flex: 6,
        child: Trend(
          key: PageStorageKey('history-trend-$station'),
          rows: history,
          names: {
            for (final p in scopedDefinitions)
              p['id'].toString():
                  '${p['station']} / ${p['name']} (${p['unit'] ?? ''})',
          },
        ),
      ),
      const Divider(),
      Container(
        height: 25,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        color: WorkbenchColors.chrome,
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '当前页变量统计 · 仅有效质量参与数值统计',
            style: TextStyle(fontSize: 10, color: WorkbenchColors.muted),
          ),
        ),
      ),
      Expanded(flex: 3, child: historyStatistics()),
      pager(),
    ],
  );

  Widget toolbar(List<Widget> children) => SizedBox(
    width: double.infinity,
    height: 42,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: children
            .map(
              (w) =>
                  Padding(padding: const EdgeInsets.only(right: 8), child: w),
            )
            .toList(),
      ),
    ),
  );
  Widget pointTable({bool operations = false}) {
    final rows = operations ? operationalRows : visible, valuesByID = live;
    return DenseTable(
      key: ValueKey(
        'point-table-$station-$page-${operations ? operationalView : 'settings'}-$sourceFilter',
      ),
      headers: operations
          ? ['变量', '工程值', '单位', '质量', '源时间', if (station.isEmpty) '站点']
          : const ['变量', '类型', '工程值', '单位', '读写', '来源', '源路径', '工程范围', '源时间'],
      initialWidths: operations
          ? [220, 115, 65, 88, 178, if (station.isEmpty) 110]
          : const [180, 75, 100, 60, 65, 110, 170, 100, 165],
      numericColumns: operations ? const {1} : const {2},
      rowCount: rows.length,
      rowKey: (i) => Key('point-row-${rows[i]['id']}'),
      cellKey: (i, col) => col == (operations ? 1 : 2)
          ? Key('value-${rows[i]['id']}')
          : col == (operations ? 4 : 8)
          ? Key('source-age-${rows[i]['id']}')
          : null,
      initialScrollOffset: tableScroll,
      onScroll: (v) => tableScroll = v,
      rowBuilder: (i) {
        final p = rows[i], r = valuesByID[rows[i]['id']] ?? <String, dynamic>{};
        return operations
            ? [
                p['name'].toString(),
                number(r['value']),
                (p['unit'] ?? '').toString(),
                qualityLabel(
                  online ? (r['quality'] ?? 'missing').toString() : 'stale',
                ),
                clock(r['source_time']),
                if (station.isEmpty) p['station'].toString(),
              ]
            : [
                p['name'].toString(),
                (p['data_type'] ?? '').toString(),
                number(r['value']),
                (p['unit'] ?? '').toString(),
                (p['rw_mode'] ?? (p['writable'] == true ? 'RW' : 'R'))
                    .toString(),
                pointSource(p),
                (p['source_path'] ?? '').toString(),
                '${number(p['min'])} ～ ${number(p['max'])}',
                clock(r['source_time']),
              ];
      },
      selected: rows.indexWhere((p) => p['id'] == selectedID),
      onSelect: (i) => selectPoint(rows[i]),
      onContext: (i, loc) => pointMenu(i, loc, rows),
      checks: operations
          ? null
          : {
              for (int i = 0; i < rows.length; i++)
                if (selected.contains(rows[i]['id'])) i,
            },
      onCheck: (i, v) => setState(() {
        final id = rows[i]['id'].toString();
        if (v && selected.length < 6) {
          selected.add(id);
        } else if (!v) {
          selected.remove(id);
        }
        acceptRuntime(runtime, connectionConfirmed: false);
      }),
    );
  }

  Widget pointMatrix() {
    final rows = operationalRows;
    return VariableMatrix(
      key: ValueKey(
        'point-matrix-$station-$operationalView-$sourceFilter-$query-$matrixCompact',
      ),
      itemCount: rows.length,
      pointBuilder: (i) => rows[i],
      liveBuilder: (id) => liveIndex[id] ?? const {},
      online: online,
      selectedID: selectedID,
      compact: matrixCompact,
      showStation: station.isEmpty,
      initialScrollOffset: matrixScroll,
      onScroll: (offset) => matrixScroll = offset,
      onSelect: (i) => selectPoint(rows[i]),
      onContext: (i, loc) => pointMenu(i, loc, rows),
    );
  }

  Widget pointWorkspace() => Column(
    children: [
      toolbar([
        SizedBox(
          width: 228,
          child: TextField(
            key: const Key('point-search'),
            controller: search,
            focusNode: searchFocus,
            decoration: const InputDecoration(
              hintText: '搜索变量、站点或单位',
              prefixIcon: Icon(Icons.search, size: 16),
            ),
            onChanged: (v) => setState(() {
              query = v;
              tableScroll = 0;
            }),
          ),
        ),
        FilledButton.icon(
          onPressed: online && !busy ? add : null,
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加点位'),
        ),
        OutlinedButton.icon(
          onPressed: online && !busy ? apply : null,
          icon: const Icon(Icons.play_arrow, size: 15),
          label: const Text('应用配置'),
        ),
        if (selected.isNotEmpty)
          TextButton(
            onPressed: () => setState(() {
              selected.clear();
              acceptRuntime(runtime, connectionConfirmed: false);
            }),
            child: Text('清除曲线 (${selected.length})'),
          ),
      ]),
      const SizedBox(height: 8),
      Expanded(
        child: points.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.developer_board_outlined,
                      size: 32,
                      color: WorkbenchColors.accent,
                    ),
                    const SizedBox(height: 12),
                    const Text('建立你的第一个站点工程'),
                    const SizedBox(height: 8),
                    const Text(
                      '添加变量，或使用模拟工程验证采集和历史流程',
                      style: TextStyle(
                        color: WorkbenchColors.muted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: online ? demo : null,
                      icon: const Icon(Icons.science_outlined, size: 16),
                      label: const Text('启动模拟工程'),
                    ),
                  ],
                ),
              )
            : pointTable(),
      ),
      SizedBox(
        height: 23,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '${visible.length} 行 · 点击查看与下设 · 右键更多操作 · 可选 6 条曲线',
            style: const TextStyle(fontSize: 10, color: WorkbenchColors.muted),
          ),
        ),
      ),
    ],
  );

  Widget inspector() {
    final p = current;
    if (p == null) return const SizedBox.shrink();
    return WriteInspector(
      key: ValueKey('write-inspector-${p['id']}'),
      api: widget.api,
      point: p,
      sample: live[p['id']] ?? {},
      online: online,
      version: (runtime['version'] ?? '').toString(),
      onEdit: () => add(existing: p),
      onRefresh: _poll,
      commands: commandResults,
    );
  }

  Widget trendWorkspace() {
    final names = {
      for (final p in scopedPoints)
        p['id'].toString(): '${p['station']} / ${p['name']}',
    };
    return Column(
      children: [
        toolbar([
          const Text('最近 3 分钟 · 实时工程值'),
          OutlinedButton(
            onPressed: () => setState(() => page = 0),
            child: const Text('选择曲线'),
          ),
          TextButton(
            onPressed: () => setState(() => buffer.clear()),
            child: const Text('清空显示'),
          ),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Trend(
              key: PageStorageKey('live-trend-$station'),
              rows: trendRows,
              names: names,
            ),
          ),
        ),
      ],
    );
  }

  Widget eventWorkspace() => Column(
    children: [
      toolbar([
        FilledButton.icon(
          onPressed: online && !busy
              ? () async {
                  final r = await ruleEditor(
                    context,
                    widget.api,
                    scopedPoints,
                    rules,
                    station: station,
                  );
                  if (r != null) await _load();
                }
              : null,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加事件'),
        ),
        OutlinedButton(
          onPressed: () => act(() async {
            final r = await widget.api.request('GET', '/api/v1/executions');
            setState(
              () => logs = objects(r['items'])
                  .where(
                    (entry) =>
                        station.isEmpty ||
                        entry['station'] == station ||
                        scopedRules.any(
                          (rule) => rule['id'] == entry['rule_id'],
                        ),
                  )
                  .toList(),
            );
          }),
          child: const Text('执行记录'),
        ),
      ]),
      const SizedBox(height: 8),
      Expanded(
        child: scopedRules.isEmpty
            ? const Center(child: Text('将多个点位条件组合成事件，执行下设或存储动作。'))
            : ListView.separated(
                itemCount: scopedRules.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, i) {
                  final r = scopedRules[i];
                  return ListTile(
                    dense: true,
                    leading: Switch(
                      value: r['enabled'] == true,
                      onChanged: (v) => act(() async {
                        final next = rules
                            .map((x) => Map<String, dynamic>.from(x))
                            .toList();
                        next[next.indexWhere(
                              (item) => item['id'] == r['id'],
                            )]['enabled'] =
                            v;
                        await widget.api.request(
                          'PUT',
                          '/api/v1/rules',
                          body: {'items': next},
                        );
                        await _poll();
                      }),
                    ),
                    title: Text(r['name'].toString()),
                    subtitle: Text(
                      '${r['logic'] == 'and' ? '同时满足' : '任一满足'} · ${objects(r['conditions']).length} 个条件 · ${objects(r['actions']).length} 个动作',
                    ),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: '编辑规则',
                          onPressed: () async {
                            final result = await ruleEditor(
                              context,
                              widget.api,
                              scopedPoints,
                              rules,
                              station: station,
                              existing: r,
                            );
                            if (result != null) await _load();
                          },
                          icon: const Icon(Icons.edit_outlined, size: 17),
                        ),
                        IconButton(
                          tooltip: '删除规则',
                          onPressed: () => act(() async {
                            await widget.api.request(
                              'PUT',
                              '/api/v1/rules',
                              body: {
                                'items': rules
                                    .where((x) => x['id'] != r['id'])
                                    .toList(),
                              },
                            );
                            await _load();
                          }),
                          icon: const Icon(Icons.delete_outline, size: 17),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      if (logs.isNotEmpty) ...[
        const Divider(),
        SizedBox(
          height: 180,
          child: ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              title: Text(
                '${clock(logs[i]['at'])} · ${logs[i]['name'] ?? logs[i]['type']}',
              ),
              subtitle: Text(
                logs[i]['results'] != null
                    ? objects(logs[i]['results'])
                          .map((r) => stateLabel(r['state'].toString()))
                          .join(' → ')
                    : stateLabel(
                        (logs[i]['result'] as Json?)?['state']?.toString() ??
                            '',
                      ),
              ),
              onTap: () => showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('执行明细'),
                  content: SizedBox(
                    width: 580,
                    child: SingleChildScrollView(
                      child: SelectableText(pretty(logs[i])),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
  Future<void> pickHistoryPoint() async {
    final definitions = scopedDefinitions;
    final controller = TextEditingController();
    final selectedPoint = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final term = controller.text.toLowerCase();
          final rows = term.isEmpty
              ? definitions
              : definitions
                    .where(
                      (p) => '${p['station']} ${p['name']}'
                          .toLowerCase()
                          .contains(term),
                    )
                    .toList();
          return AlertDialog(
            title: const Text('选择历史变量'),
            content: SizedBox(
              width: 480,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索站点或变量名称',
                      prefixIcon: Icon(Icons.search, size: 17),
                    ),
                    onChanged: (_) => update(() {}),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('全部变量'),
                    onTap: () => Navigator.pop(context, ''),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemExtent: 38,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        title: Text(
                          '${rows[i]['station']} / ${rows[i]['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () =>
                            Navigator.pop(context, rows[i]['id'].toString()),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    // Dispose after route transitions have finished using the text field.
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (selectedPoint != null && mounted) {
      setState(() {
        historyPoint = selectedPoint;
        boundary = 0;
        offset = 0;
      });
    }
  }

  Widget filters() => Column(
    children: [
      toolbar([
        SizedBox(
          width: 200,
          child: OutlinedButton.icon(
            key: const Key('history-point-select'),
            onPressed: busy ? null : pickHistoryPoint,
            icon: const Icon(Icons.search, size: 15),
            label: Text(
              historyPoint.isEmpty
                  ? '全部变量'
                  : historyDefinitions
                        .firstWhere(
                          (p) => p['id'] == historyPoint,
                          orElse: () => {'name': historyPoint},
                        )['name']
                        .toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            key: ValueKey('quality-$station-$quality'),
            initialValue: quality,
            decoration: const InputDecoration(labelText: '质量'),
            items: ['', 'good', 'bad', 'stale', 'imported']
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(v.isEmpty ? '全部质量' : qualityLabel(v)),
                  ),
                )
                .toList(),
            onChanged: busy ? null : (v) => setState(() => quality = v ?? ''),
          ),
        ),
        SizedBox(
          width: 115,
          child: TextField(
            // Import restores the target station before its history is ready.
            // Keep filters locked until that whole scope transition completes.
            enabled: !busy,
            controller: min,
            decoration: const InputDecoration(labelText: '最小值'),
          ),
        ),
        SizedBox(
          width: 115,
          child: TextField(
            enabled: !busy,
            controller: max,
            decoration: const InputDecoration(labelText: '最大值'),
          ),
        ),
        FilledButton.icon(
          onPressed: busy ? null : () => queryHistory(reset: true),
          icon: const Icon(Icons.filter_alt_outlined, size: 16),
          label: const Text('筛选'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  historyPoint = '';
                  quality = '';
                  min.clear();
                  max.clear();
                  from.clear();
                  to.clear();
                  boundary = 0;
                }),
          child: const Text('清除'),
        ),
      ]),
      const SizedBox(height: 8),
      toolbar([
        SizedBox(
          width: 245,
          child: TextField(
            enabled: !busy,
            controller: from,
            decoration: const InputDecoration(
              labelText: '开始时间 ISO（可选）',
              hintText: '2026-10-01T00:00:00Z',
            ),
          ),
        ),
        SizedBox(
          width: 245,
          child: TextField(
            enabled: !busy,
            controller: to,
            decoration: const InputDecoration(labelText: '结束时间 ISO（可选）'),
          ),
        ),
        if (station.isNotEmpty) Chip(label: Text(station)),
      ]),
    ],
  );
  Widget summary() => Container(
    width: double.infinity,
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in {
            '样本': stats['count'] ?? 0,
            '最小': number(stats['min']),
            '最大': number(stats['max']),
            '均值': number(stats['mean']),
          }.entries)
            Padding(
              padding: const EdgeInsets.only(right: 28),
              child: Text(
                '${entry.key}  ${entry.value}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    ),
  );
  Widget historyTable() => DenseTable(
    headers: const ['源时间', '站点', '点位', '数值', '单位', '质量', '配置版本'],
    rowCount: history.length,
    numericColumns: const {3},
    rowBuilder: (i) {
      final r = history[i];
      return [
        clock(r['source_time']),
        r['station'].toString(),
        r['name'].toString(),
        number(r['value']),
        r['unit'].toString(),
        qualityLabel(r['quality'].toString()),
        r['version'].toString(),
      ];
    },
  );
  Widget pager() => Row(
    children: [
      Text(
        '第 ${offset ~/ 1000 + 1} 页 · ${history.length} 行',
        style: const TextStyle(fontSize: 11),
      ),
      const Spacer(),
      TextButton(
        onPressed: offset == 0 || busy
            ? null
            : () {
                setState(() => offset = math.max(0, offset - 1000));
                queryHistory();
              },
        child: const Text('上一页'),
      ),
      TextButton(
        onPressed: history.length < 1000 || busy
            ? null
            : () {
                setState(() => offset += 1000);
                queryHistory();
              },
        child: const Text('下一页'),
      ),
    ],
  );
  Widget historyWorkspace() => Column(
    children: [
      toolbar([
        Switch(
          value: policy['enabled'] == true,
          onChanged: busy ? null : changeStorage,
        ),
        const Text('独立存储'),
        TextButton(
          onPressed: busy
              ? null
              : () => act(() async {
                  await widget.api.request(
                    'POST',
                    '/api/v1/snapshot',
                    query: {if (station.isNotEmpty) 'station': station},
                  );
                }, success: '当前快照已存储'),
          child: const Text('存储快照'),
        ),
        OutlinedButton(onPressed: storageOptions, child: const Text('存储策略')),
        const Text('无需开始检测', style: TextStyle(fontSize: 11)),
      ]),
      const SizedBox(height: 8),
      filters(),
      const SizedBox(height: 8),
      summary(),
      const SizedBox(height: 8),
      Expanded(child: historyTable()),
      pager(),
    ],
  );
  Future<void> storageOptions() async {
    final interval = TextEditingController(
          text: (policy['interval_ms'] ?? 1000).toString(),
        ),
        retention = TextEditingController(
          text: (policy['retention_days'] ?? 30).toString(),
        );
    bool changed = policy['changed_only'] == true;
    await showDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => EditorFrame(
          title: '独立存储策略',
          controllers: [interval, retention],
          content: Column(
            children: [
              field(interval, '周期（毫秒，最小 200）'),
              field(retention, '保留天数'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅在值／质量／配置变化时存储'),
                value: changed,
                onChanged: (v) => update(() => changed = v),
              ),
              Text(
                selected.isEmpty ? '范围：全部点位' : '范围：当前选择 ${selected.length} 个点位',
              ),
            ],
          ),
          save: () async {
            final p = policy;
            p['interval_ms'] = int.parse(interval.text);
            p['retention_days'] = int.parse(retention.text);
            p['changed_only'] = changed;
            p['point_ids'] = selected.toList();
            p['station'] = station;
            await widget.api.request(
              'PUT',
              '/api/v1/storage',
              body: p,
              query: {if (station.isNotEmpty) 'station': station},
            );
            await loadPolicy();
            return true;
          },
        ),
      ),
    );
    await _poll();
  }

  Widget reportWorkspace() => Column(
    children: [
      toolbar([
        FilledButton.icon(
          onPressed: busy ? null : upload,
          icon: const Icon(Icons.upload_file, size: 16),
          label: const Text('导入 Excel / CSV'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => export('xlsx'),
          child: const Text('导出 XLSX'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => export('csv'),
          child: const Text('导出 CSV'),
        ),
      ]),
      const SizedBox(height: 8),
      filters(),
      const SizedBox(height: 8),
      summary(),
      const SizedBox(height: 8),
      Container(
        height: 28,
        color: WorkbenchColors.chrome,
        child: Row(
          children: [
            TextButton(
              onPressed: () => setState(() => reportSamples = false),
              child: const Text('当前页统计', style: TextStyle(fontSize: 11)),
            ),
            TextButton(
              onPressed: () => setState(() => reportSamples = true),
              child: const Text('样本明细', style: TextStyle(fontSize: 11)),
            ),
            const Spacer(),
            const Text(
              '导出使用完整筛选范围  ',
              style: TextStyle(fontSize: 10, color: WorkbenchColors.muted),
            ),
          ],
        ),
      ),
      Expanded(child: reportSamples ? historyTable() : historyStatistics()),
      pager(),
      if (scopedJobs.isNotEmpty)
        SizedBox(
          height: 100,
          child: ListView.builder(
            itemCount: scopedJobs.length,
            itemBuilder: (context, i) {
              final j = scopedJobs[i],
                  id = j['id'].toString(),
                  state = j['state'].toString();
              return ListTile(
                dense: true,
                leading: Icon(
                  state == 'completed'
                      ? Icons.task_alt
                      : state == 'failed'
                      ? Icons.error_outline
                      : Icons.pending_outlined,
                  size: 18,
                ),
                title: Text(
                  '${j['format'].toString().toUpperCase()} · ${stateLabel(state)} · ${j['rows']} 行',
                ),
                subtitle: Text(
                  state == 'completed'
                      ? '已按当前筛选范围生成报表，可保存到本地'
                      : (j['message'] ?? '').toString(),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Wrap(
                  children: [
                    if (state == 'completed')
                      IconButton(
                        tooltip: '保存报表',
                        onPressed: () => act(() async {
                          final bytes = await widget.api.download(id);
                          final saved = await saveFile(
                            bytes,
                            'universal-hmi.${j['format']}',
                          );
                          if (saved && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('报表已交给文件保存器')),
                            );
                          }
                        }),
                        icon: const Icon(Icons.download, size: 17),
                      ),
                    if (state == 'queued' || state == 'running')
                      IconButton(
                        tooltip: '取消任务',
                        onPressed: () => act(() async {
                          await widget.api.request(
                            'POST',
                            '/api/v1/jobs/$id/cancel',
                          );
                          await _load();
                        }),
                        icon: const Icon(Icons.close, size: 17),
                      )
                    else
                      IconButton(
                        tooltip: '删除任务和文件',
                        onPressed: () => act(() async {
                          await widget.api.request(
                            'DELETE',
                            '/api/v1/jobs/$id',
                          );
                          await _load();
                        }),
                        icon: const Icon(Icons.delete_outline, size: 17),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
    ],
  );
  Widget sourceWorkspace() => Column(
    children: [
      toolbar([
        FilledButton.icon(
          onPressed: busy
              ? null
              : () async {
                  final r = await sourceEditor(context, widget.api, sources);
                  if (r != null) await _load();
                },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加 MQTT 来源'),
        ),
        OutlinedButton(
          onPressed: busy ? null : demo,
          child: Text(runtime['demo'] == true ? '停止模拟采集' : '启动 30 站模拟'),
        ),
      ]),
      const SizedBox(height: 8),
      Expanded(
        child: sources.isEmpty
            ? const Center(child: Text('一个来源可包含多个站点，点位按源路径映射到不同站点。'))
            : ListView.separated(
                itemCount: sources.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, i) {
                  final s = sources[i],
                      id = s['id'].toString(),
                      state = ((runtime['source_states'] as Map?)?[id] ?? '未连接')
                          .toString();
                  return ListTile(
                    title: Text(s['name'].toString()),
                    subtitle: Text('${s['broker']} · ${s['topic']}\n$state'),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: '编辑来源',
                          onPressed: busy
                              ? null
                              : () async {
                                  final r = await sourceEditor(
                                    context,
                                    widget.api,
                                    sources,
                                    existing: s,
                                  );
                                  if (r != null) await _load();
                                },
                          icon: const Icon(Icons.edit_outlined, size: 17),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => act(() async {
                                  await widget.api.request(
                                    'POST',
                                    '/api/v1/sources/$id/connect',
                                  );
                                  await _poll();
                                }),
                          child: const Text('连接'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => act(() async {
                                  await widget.api.request(
                                    'POST',
                                    '/api/v1/sources/$id/disconnect',
                                  );
                                  await _poll();
                                }),
                          child: const Text('断开'),
                        ),
                        IconButton(
                          tooltip: '删除来源',
                          onPressed: busy
                              ? null
                              : () => act(() async {
                                  await widget.api.request(
                                    'PUT',
                                    '/api/v1/sources',
                                    body: {
                                      'items': sources
                                          .where((x) => x['id'] != id)
                                          .toList(),
                                    },
                                  );
                                  await _load();
                                }),
                          icon: const Icon(Icons.delete_outline, size: 17),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );
}

String stateLabel(String state) => switch (state) {
  'readback_confirmed' => '读回确认',
  'acknowledged' => '设备已应答（等待读回）',
  'sent' => '已发送（设备结果待确认）',
  'unknown' => '结果未知',
  'accepted' => '已接受',
  'queued' => '排队中',
  'running' => '运行中',
  'completed' => '已完成',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => state,
};

String utcOffsetLabel(Duration offset) {
  final totalMinutes = offset.inMinutes;
  final absolute = totalMinutes.abs();
  final hours = (absolute ~/ 60).toString().padLeft(2, '0');
  final minutes = (absolute % 60).toString().padLeft(2, '0');
  return 'UTC${totalMinutes < 0 ? '-' : '+'}$hours:$minutes';
}

String sourceTypeLabel(String source) => switch (source) {
  'manual' => '手工输入',
  'simulator' => '模拟采集',
  'virtual' => '计算变量',
  _ => source,
};

String pointSource(Json point) {
  final id = (point['source_id'] ?? '').toString();
  return id.isEmpty ? (point['source_type'] ?? '').toString() : id;
}
