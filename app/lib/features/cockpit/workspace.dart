import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'charts.dart';
import 'roster.dart';
import 'sample.dart';

const cockpitPage = 22;
const cockpitPath = '/api/v1/cockpit';

class CockpitWorkspace extends StatefulWidget {
  const CockpitWorkspace({super.key, required this.api});
  final PlatformApi api;

  @override
  State<CockpitWorkspace> createState() => _CockpitWorkspaceState();
}

class _CockpitWorkspaceState extends State<CockpitWorkspace> {
  final sections = <String, Json>{};
  final errors = <String, String>{};
  final busy = <String>{};
  Timer? timer;
  int tick = 0;

  @override
  void initState() {
    super.initState();
    if (cockpitSample) {
      unawaited(load('live'));
    } else {
      for (final part in ['live', 'history', 'weather']) {
        unawaited(load(part));
      }
      timer = Timer.periodic(const Duration(seconds: 5), (_) {
        tick++;
        unawaited(load('live'));
        if (tick % 4 == 0) unawaited(load('history'));
        if (tick % 12 == 0) unawaited(load('weather'));
      });
    }
  }

  Future<void> load(String part) async {
    if (!busy.add(part)) return;
    try {
      final data = await widget.api.request('GET', '$cockpitPath/$part');
      if (!mounted) return;
      setState(() {
        sections[part] = data;
        errors.remove(part);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => errors[part] = '暂不可用');
    } finally {
      busy.remove(part);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = cockpitSample ? sampleCockpit : sections;
    return CockpitDisplay(
      live: !cockpitSample && errors.containsKey('live')
          ? const {}
          : data['live'] ?? const {},
      history: data['history'] ?? const {},
      weather: data['weather'] ?? const {},
      title: (sections['live']?['title'] ?? '庄河供热运行指挥中心').toString(),
      errors: errors,
    );
  }
}

class CockpitDisplay extends StatelessWidget {
  const CockpitDisplay({
    super.key,
    required this.live,
    required this.history,
    required this.weather,
    required this.title,
    this.errors = const {},
  });
  final Json live, history, weather;
  final String title;
  final Map<String, String> errors;

  Json get today => history['today'] as Json? ?? const {};
  List<Json> list(Json data, String key) =>
      data[key] is List ? objects(data[key]) : const [];

  Widget empty(String text) => Center(
    child: Text(text, style: const TextStyle(color: dim, fontSize: 15)),
  );

  Widget? pageDetail(String? range) => range == null
      ? null
      : Text(range, style: const TextStyle(color: dim, fontSize: 12));

  String get historyStatus =>
      errors['history'] ?? history['notice']?.toString() ?? '正在加载统计';
  String get liveStatus =>
      errors['live'] ?? live['notice']?.toString() ?? '正在加载实时数据';

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0, -.86),
        radius: 1.36,
        colors: [Color(0xff12365d), Color(0xff06132d), Color(0xff040d21)],
        stops: [0, .63, 1],
      ),
    ),
    child: LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth <= 0 || box.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        // The layout dimensions follow the aspect ratio while text and icons
        // share one scale. Panels use all available space without stretching glyphs.
        final scale = math.min(box.maxWidth / 1720, box.maxHeight / 888);
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: box.maxWidth / scale,
            height: box.maxHeight / scale,
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Color(0xffeaf6ff), fontSize: 15),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 11),
                child: Column(
                  children: [
                    SizedBox(height: 66, child: CockpitTitle(title)),
                    const SizedBox(height: 8),
                    SizedBox(height: 66, child: kpis()),
                    const SizedBox(height: 11),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 25,
                            child: Column(
                              children: [
                                Expanded(flex: 55, child: ranking()),
                                const SizedBox(height: 12),
                                Expanded(flex: 45, child: loads()),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 50,
                            child: Column(
                              children: [
                                Expanded(flex: 34, child: hourly()),
                                const SizedBox(height: 12),
                                Expanded(flex: 34, child: heatmap()),
                                const SizedBox(height: 12),
                                Expanded(flex: 32, child: weekly()),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 25,
                            child: Column(
                              children: [
                                Expanded(flex: 60, child: forecast()),
                                const SizedBox(height: 9),
                                Expanded(flex: 40, child: stationStatus()),
                                const SizedBox(height: 9),
                                SizedBox(height: 105, child: attention()),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(height: 218, child: liveRows()),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  String clock(Object? input) {
    final t = DateTime.tryParse(input?.toString() ?? '');
    if (t == null) return '—';
    final local = t.toUtc().add(const Duration(hours: 8));
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Widget kpis() {
    final stations = list(live, 'stations');
    final online = stations.where((s) => s['state'] == 'online').length;
    final attention = stations
        .where((s) => const {'delayed', 'offline'}.contains(s['state']))
        .length;
    final metrics = today['metrics'] as Json? ?? const {};
    final items = [
      ('实时供热功率', reading(live['power'], 1), 'MW', Icons.waves_rounded, ice),
      (
        '今日耗热',
        reading(metrics['heat']),
        'GJ',
        Icons.local_fire_department_outlined,
        mint,
      ),
      (
        '今日用电',
        reading(metrics['electricity']),
        'kWh',
        Icons.bolt_rounded,
        violet,
      ),
      (
        '今日补水',
        reading(metrics['water'], 1),
        't',
        Icons.water_drop_outlined,
        ice,
      ),
      (
        '在线站数',
        stations.isEmpty ? '—' : '$online/${stations.length}',
        '',
        Icons.circle_outlined,
        mint,
      ),
      (
        '运行关注',
        stations.isEmpty ? '—' : '$attention',
        '',
        Icons.warning_amber_rounded,
        amber,
      ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff123a62), Color(0xff091e40), Color(0xff102e52)],
        ),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xff3781ae)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              const VerticalDivider(
                width: 1,
                indent: 12,
                endIndent: 12,
                color: Color(0xff305678),
              ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (i == 4)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        value: stations.isEmpty ? 0 : online / stations.length,
                        strokeWidth: 5,
                        color: mint,
                        backgroundColor: const Color(0xff375475),
                      ),
                    )
                  else
                    Icon(
                      items[i].$4,
                      size: 33,
                      color: items[i].$5,
                      shadows: [
                        Shadow(
                          color: items[i].$5.withValues(alpha: .6),
                          blurRadius: 13,
                        ),
                      ],
                    ),
                  const SizedBox(width: 13),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(items[i].$1, style: const TextStyle(color: dim)),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            items[i].$2,
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              height: 1.13,
                              color: items[i].$5,
                            ),
                          ),
                          if (items[i].$3.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(items[i].$3),
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget ranking() {
    final all = list(today, 'ranking');
    final names = history['rank_names'] as Json? ?? const {};
    final limit = math.max(1.0, numberOf(all.firstOrNull?['value']) ?? 1);
    final old = history['yesterday'] as Json? ?? const {};
    final previous = old['station_hours'] as Json? ?? const {};
    final current = today['station_hours'] as Json? ?? const {};
    final closed = (today['closed_hours'] as num?)?.toInt() ?? 0;
    final cutoff = '${closed.toString().padLeft(2, '0')}:00';
    String delta(String id) {
      final a = valuesOf(current[id]).take(closed).toList();
      final b = valuesOf(previous[id]).take(closed).toList();
      if (closed == 0 ||
          a.length != closed ||
          b.length != closed ||
          a.any((v) => v == null) ||
          b.any((v) => v == null)) {
        return '—';
      }
      final base = b.whereType<double>().fold(0.0, (x, y) => x + y);
      if (base == 0) return '—';
      final change =
          100 *
          (a.whereType<double>().fold(0.0, (x, y) => x + y) - base) /
          base;
      return '${change > 0 ? '+' : ''}${reading(change, 1)}%';
    }

    return CockpitRoster(
      count: all.length,
      minimumRowHeight: 27,
      buildRow: (index) {
        final row = all[index];
        return Row(
          children: [
            Container(
              width: 22,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: index < 3
                    ? const Color(0xff22587b)
                    : const Color(0xff142d4d),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '${numberOf(row['value']) == null ? '—' : index + 1}',
                style: TextStyle(color: index == 0 ? amber : ice, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 154,
              child: Text(
                '${names[row['id']] ?? row['name']}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(child: meter((numberOf(row['value']) ?? 0) / limit, mint)),
            const SizedBox(width: 8),
            SizedBox(
              width: 60,
              child: Text(reading(row['value'], 1), textAlign: TextAlign.right),
            ),
            SizedBox(
              width: 65,
              child: Text(
                delta('${row['id']}'),
                textAlign: TextAlign.right,
                style: const TextStyle(color: dim, fontSize: 13),
              ),
            ),
          ],
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '换热站耗热排行',
          all.isEmpty ? empty(historyStatus) : body,
          pinnedHeader: all.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '站点',
                          style: TextStyle(color: dim, fontSize: 12),
                        ),
                      ),
                      Text(
                        closed > 0
                            ? '今日 GJ  /  较昨同期至 $cutoff'
                            : '今日 GJ  /  较昨日同期',
                        style: const TextStyle(color: dim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
          detail: range,
        );
      },
    );
  }

  Widget meter(double ratio, Color color) => SizedBox(
    height: 8,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff143759),
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        widthFactor: ratio.clamp(0.0, 1.0),
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [const Color(0xff147dc0), color]),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    ),
  );

  Widget loads() {
    final groups = list(live, 'groups');
    final limit = groups.fold(
      1.0,
      (top, row) => math.max(top, numberOf(row['power']) ?? 0),
    );
    return CockpitRoster(
      count: groups.length,
      minimumRowHeight: 28,
      buildRow: (index) {
        final group = groups[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 132,
                child: Text(
                  '${group['name']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                child: meter(
                  group['load_percent'] == null
                      ? (numberOf(group['power']) ?? 0) / limit
                      : (numberOf(group['load_percent']) ?? 0) / 100,
                  ice,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 118,
                child: Text(
                  '${reading(group['power'], 1)} MW'
                  '${group['load_percent'] == null ? '' : ' · ${reading(group['load_percent'])}%'}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: ice,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '站所实时负荷',
          groups.isEmpty ? empty(liveStatus) : body,
          detail: range,
        );
      },
    );
  }

  Widget hourly() {
    final previous = history['yesterday'] as Json? ?? const {};
    final complete = valuesOf(today['hours']);
    final partial = valuesOf(today['partial_hours']);
    final coverage = valuesOf(today['hour_coverage']);
    final shown = [
      for (var i = 0; i < math.max(complete.length, partial.length); i++)
        complete.elementAtOrNull(i) ?? partial.elementAtOrNull(i),
    ];
    final incomplete = {
      for (final (i, value) in partial.indexed)
        if (value != null) i,
    };
    final leastCovered = incomplete
        .map(coverage.elementAtOrNull)
        .whereType<double>()
        .fold<double?>(
          null,
          (low, count) => low == null ? count : math.min(low, count),
        );
    final closed = (today['closed_hours'] as num?)?.toInt();
    final cutoff = closed == null
        ? null
        : '${closed.toString().padLeft(2, '0')}:00';
    return CockpitPanel(
      '全网分时耗热',
      Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: hourlyPlot(
              cutoff == null ? '今日' : '今日 · 至 $cutoff',
              shown,
              mint,
              bars: true,
              outlined: incomplete,
              emptyLabel: closed == 0
                  ? '今日首小时尚未结束'
                  : today.isEmpty
                  ? historyStatus
                  : '今日无有效小时数据',
            ),
          ),
          const VerticalDivider(width: 20, color: Color(0xff284667)),
          Expanded(
            child: hourlyPlot(
              '昨日',
              valuesOf(previous['hours']),
              violet,
              emptyLabel: '昨日无完整小时数据',
            ),
          ),
        ],
      ),
      detail: pageDetail('GJ · 两图各自刻度'),
      pinnedFooter: incomplete.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '▭  缺站小时显示已到数小计'
                '${leastCovered == null ? '' : ' · 最少 ${leastCovered.toInt()}/${today['station_count']} 站'}',
                style: const TextStyle(color: amber, fontSize: 12),
              ),
            ),
    );
  }

  Widget hourlyPlot(
    String label,
    List<double?> values,
    Color color, {
    required String emptyLabel,
    bool bars = false,
    Set<int> outlined = const {},
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: TextStyle(color: color, fontSize: 13)),
      Expanded(
        child: values.every((value) => value == null)
            ? empty(emptyLabel)
            : CockpitPlot(
                values: values,
                labels: const ['00:00', '06:00', '12:00', '18:00', '24:00'],
                color: color,
                bars: bars,
                outlined: outlined,
                bucketed: true,
                showScale: true,
                startAtZero: true,
              ),
      ),
    ],
  );

  static const hours = [
    '00:00',
    '04:00',
    '08:00',
    '12:00',
    '16:00',
    '20:00',
    '24:00',
  ];

  Widget heatmap() {
    const nameWidth = 160.0;
    final part = history['zones'] as Json? ?? const {};
    final rows = list(part, 'rows');
    final maximum = rows
        .expand((r) => valuesOf(r['values']))
        .whereType<double>()
        .fold(1.0, math.max);
    return HeatmapWave(
      builder: (phase) => CockpitRoster(
        count: rows.length,
        minimumRowHeight: 21,
        buildRow: (index) {
          final row = rows[index];
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: nameWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${row['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              Expanded(
                child: HeatmapCells(
                  values: valuesOf(row['values']),
                  maximum: maximum,
                  phase: phase,
                  row: index,
                ),
              ),
            ],
          );
        },
        buildPanel: (body, range) {
          return CockpitPanel(
            '站区分时耗热',
            rows.isEmpty
                ? empty(part['notice']?.toString() ?? historyStatus)
                : body,
            pinnedFooter: rows.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: nameWidth, top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final h in hours)
                          Text(
                            h,
                            style: const TextStyle(color: dim, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
            detail: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('低', style: TextStyle(color: dim, fontSize: 11)),
                const SizedBox(width: 7),
                Container(
                  width: 55,
                  height: 6,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xff173e86), mint],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 7),
                const Text(
                  '高 · GJ',
                  style: TextStyle(color: dim, fontSize: 11),
                ),
                const SizedBox(width: 11),
                range,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget weekly() {
    final week = history['week'] as Json? ?? const {};
    final metrics = today['metrics'] as Json? ?? const {};
    final labels = [
      if (week['labels'] is List)
        for (final v in week['labels'] as List) '$v',
    ];
    final spacedLabels = [
      for (final (i, label) in labels.indexed)
        i == 0 || i == labels.length ~/ 2 || i == labels.length - 1
            ? label
            : '',
    ];
    const groups = [
      ('耗热量', 'GJ', 'heat', mint, 0),
      ('用电量', 'kWh', 'electricity', violet, 0),
      ('补水量', 't', 'water', ice, 1),
    ];
    return CockpitPanel(
      '近7天用量',
      week.isEmpty && metrics.isEmpty
          ? empty(historyStatus)
          : Row(
              children: [
                for (final (i, group) in groups.indexed) ...[
                  if (i > 0)
                    const VerticalDivider(width: 22, color: Color(0xff284667)),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final current = numberOf(metrics[group.$3]);
                        final series = valuesOf(week[group.$3]);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Expanded(
                                  child: Text(
                                    group.$1,
                                    style: const TextStyle(
                                      color: dim,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                Text(
                                  reading(current, group.$5),
                                  style: TextStyle(
                                    color: group.$4,
                                    fontSize: 23,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  group.$2,
                                  style: const TextStyle(
                                    color: dim,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Expanded(
                              child: series.every((v) => v == null)
                                  ? empty('暂无有效用量')
                                  : CockpitPlot(
                                      values: series,
                                      labels: spacedLabels,
                                      color: group.$4,
                                      bars: i == 0,
                                      startAtZero: i == 0,
                                      showScale: true,
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
      detail: week.isEmpty && metrics.isEmpty
          ? null
          : pageDetail(
              today['at'] == null
                  ? '前6天日用量 · 今日累计'
                  : '前6天日用量 · 今日累计至 ${clock(today['at'])}',
            ),
    );
  }

  Widget forecast() {
    final days = list(weather, 'daily');
    final hourly = valuesOf(weather['hourly']);
    final outdoor = numberOf(live['outdoor']);
    final current = numberOf(weather['current']);
    final condition = weather['condition'] as String? ?? '';
    final night = weather['night'];
    final labels = weather['labels'] is List
        ? [for (final label in weather['labels'] as List) '$label']
        : <String>[];
    // The weather API labels hours 0, 6, 12, 18 and the final forecast hour.
    final hourLabels = hourly.length == 24 && labels.length == 5
        ? [
            for (var i = 0; i < hourly.length; i++)
              if (i == 23)
                labels.last
              else if (i % 6 == 0)
                labels[i ~/ 6]
              else
                '',
          ]
        : labels;
    Widget temperature(String label, double? value, Color color) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: dim, fontSize: 13, height: 1.2),
            ),
            Text(
              value == null ? '—' : '${reading(value, 1)} °C',
              style: TextStyle(
                color: color,
                fontSize: 24,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return CockpitPanel(
      '天气预报',
      Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                temperature('现场实测', outdoor, mint),
                const VerticalDivider(
                  width: 22,
                  indent: 6,
                  endIndent: 6,
                  color: Color(0xff284667),
                ),
                temperature(
                  condition.isEmpty ? '和风实况' : '和风实况 · $condition',
                  current,
                  ice,
                ),
                if (night != null)
                  Expanded(
                    child: Text(
                      '今晚最低 ${reading(night)} °C\n预计 ${clock(weather['night_at'])}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: dim, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
          if (hourly.every((value) => value == null))
            Expanded(
              child: empty(
                errors['weather'] ?? weather['notice']?.toString() ?? '正在加载预报',
              ),
            )
          else ...[
            const Row(
              children: [
                Text('未来24小时气温', style: TextStyle(color: dim, fontSize: 13)),
                Spacer(),
                Text('°C', style: TextStyle(color: dim, fontSize: 12)),
              ],
            ),
            Expanded(
              child: CockpitPlot(
                values: hourly,
                labels: hourLabels,
                area: true,
                showScale: true,
              ),
            ),
          ],
          if (days.isNotEmpty)
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  for (final (i, day) in days.take(3).indexed)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            [
                              const ['明天', '后天', '大后天'][i],
                              if (day['condition'] case final String condition
                                  when condition.isNotEmpty)
                                condition,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: dim, fontSize: 12),
                          ),
                          Text(
                            '${reading(day['low'])}° / ${reading(day['high'])}°',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      detail: pageDetail(
        hourly.isNotEmpty && weather['notice'] is String
            ? weather['notice'] as String
            : '和风天气',
      ),
    );
  }

  Color stateColor(Object? state) => switch (state) {
    'online' => mint,
    'delayed' => amber,
    'offline' => const Color(0xffff817d),
    _ => const Color(0xff91a5bf),
  };

  Widget stationStatus() {
    final stations = list(live, 'stations');
    Widget statusRow(Json row) {
      final name = row['name'].toString();
      final color = stateColor(row['state']);
      final label = switch (row['state']) {
        'delayed' => '延迟',
        'unknown' => '未采样',
        final state => stateLabel(state),
      };
      return Semantics(
        container: true,
        excludeSemantics: true,
        label: '$name $label',
        child: Row(
          children: [
            Icon(Icons.circle, size: 6, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      );
    }

    return CockpitRoster(
      count: (stations.length + 1) ~/ 2,
      minimumRowHeight: 23,
      idleDetail: stations.isEmpty ? null : '共 ${stations.length} 站',
      formatRange: (first, last) =>
          '${first * 2 - 1}–${math.min(last * 2, stations.length)} / ${stations.length} 站',
      buildRow: (index) => Row(
        children: [
          Expanded(child: statusRow(stations[index * 2])),
          if (stations.length > 1) ...[
            const VerticalDivider(width: 22, color: Color(0xff2b526e)),
            Expanded(
              child: index * 2 + 1 < stations.length
                  ? statusRow(stations[index * 2 + 1])
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
      buildPanel: (body, range) => CockpitPanel(
        '站点在线状态',
        stations.isEmpty ? empty(liveStatus) : body,
        detail: range,
      ),
    );
  }

  String stateLabel(Object? state) => switch (state) {
    'online' => '在线',
    'delayed' => '采样延迟',
    'offline' => '离线',
    _ => '未收到数据',
  };

  Widget attention() {
    final all = list(live, 'stations');
    final rows = all
        .where((s) => const {'delayed', 'offline'}.contains(s['state']))
        .toList();
    return CockpitRoster(
      count: rows.length,
      minimumRowHeight: 25,
      buildRow: (index) {
        final row = rows[index];
        return Row(
          children: [
            Icon(Icons.circle, size: 8, color: stateColor(row['state'])),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${row['name']}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1),
              ),
            ),
            Text(
              stateLabel(row['state']),
              style: TextStyle(
                color: stateColor(row['state']),
                fontSize: 13,
                height: 1,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${(numberOf(row['age']) ?? 0) ~/ 60} 分钟',
              style: const TextStyle(color: dim, fontSize: 13, height: 1),
            ),
          ],
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '运行关注',
          rows.isEmpty ? empty(all.isEmpty ? liveStatus : '当前没有延迟或离线站点') : body,
          detail: range,
        );
      },
    );
  }

  Widget liveRows() {
    final rows = list(live, 'rows');
    final trends = history['trends'] as Json? ?? const {};
    const headers = [
      '站区',
      '供水温度',
      '回水温度',
      '供水压力',
      '回水压力',
      '瞬时流量',
      '热功率',
      '近2小时热功率',
    ];
    const keys = [
      'supply_temp',
      'return_temp',
      'supply_pressure',
      'return_pressure',
      'flow',
      'power',
    ];
    const flex = [18, 12, 12, 12, 12, 13, 12, 24];
    return CockpitRoster(
      count: rows.length,
      minimumRowHeight: 27,
      buildRow: (index) {
        final row = rows[index];
        return ColoredBox(
          color: index.isEven ? const Color(0xff102847) : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                flex: flex[0],
                child: Padding(
                  padding: const EdgeInsets.only(left: 5),
                  child: Text(
                    '${row['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              for (final (i, key) in keys.indexed)
                Expanded(
                  flex: flex[i + 1],
                  child: Text(
                    row[key] is Map
                        ? '${reading((row[key] as Map)['value'], i == 2 || i == 3 ? 2 : 1)} ${(row[key] as Map)['unit'] ?? ''}'
                        : '—',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Expanded(
                flex: flex.last,
                child: SizedBox(
                  height: 21,
                  child: valuesOf(trends[row['zone']]).every((v) => v == null)
                      ? const Text('—', style: TextStyle(color: dim))
                      : CockpitPlot(
                          values: valuesOf(trends[row['zone']]),
                          color: mint,
                          grid: false,
                        ),
                ),
              ),
            ],
          ),
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '站区实时工况',
          rows.isEmpty ? empty(liveStatus) : body,
          pinnedHeader: rows.isEmpty
              ? null
              : SizedBox(
                  height: 23,
                  child: Row(
                    children: [
                      for (final (i, header) in headers.indexed)
                        Expanded(
                          flex: flex[i],
                          child: Text(
                            header,
                            style: const TextStyle(color: dim, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
          detail: range,
        );
      },
    );
  }
}
