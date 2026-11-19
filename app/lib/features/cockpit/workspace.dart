import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'charts.dart';
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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 15),
                child: Column(
                  children: [
                    SizedBox(height: 82, child: CockpitTitle(title)),
                    const SizedBox(height: 11),
                    SizedBox(height: 77, child: kpis()),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 25,
                            child: Column(
                              children: [
                                Expanded(flex: 59, child: ranking()),
                                const SizedBox(height: 12),
                                Expanded(flex: 41, child: loads()),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 50,
                            child: Column(
                              children: [
                                Expanded(flex: 43, child: hourly()),
                                const SizedBox(height: 12),
                                Expanded(flex: 32, child: heatmap()),
                                const SizedBox(height: 12),
                                Expanded(flex: 25, child: weekly()),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 25,
                            child: Column(
                              children: [
                                Expanded(flex: 56, child: forecast()),
                                const SizedBox(height: 12),
                                Expanded(flex: 22, child: statusGrid()),
                                const SizedBox(height: 12),
                                Expanded(flex: 22, child: attention()),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(height: 179, child: liveRows()),
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
    final rows = list(today, 'ranking').take(8).toList();
    final limit = math.max(1.0, numberOf(rows.firstOrNull?['value']) ?? 1);
    final old = history['yesterday'] as Json? ?? const {};
    final previous = old['station_hours'] as Json? ?? const {};
    final current = today['station_hours'] as Json? ?? const {};
    final closed = (today['closed_hours'] as num?)?.toInt() ?? 0;
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

    return CockpitPanel(
      '换热站耗热排行',
      rows.isEmpty
          ? empty(historyStatus)
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '站点',
                          style: TextStyle(color: dim, fontSize: 12),
                        ),
                      ),
                      Text(
                        '今日 GJ   /   较昨日同期',
                        style: TextStyle(color: dim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                for (final (i, row) in rows.indexed)
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 22,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: i < 3
                                ? const Color(0xff22587b)
                                : const Color(0xff142d4d),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: i == 0 ? amber : ice,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 107,
                          child: Text(
                            '${row['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          child: meter(
                            (numberOf(row['value']) ?? 0) / limit,
                            mint,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 60,
                          child: Text(
                            reading(row['value'], 1),
                            textAlign: TextAlign.right,
                          ),
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
                    ),
                  ),
              ],
            ),
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
    final groups = list(live, 'groups').take(6).toList();
    final limit = groups.fold(
      1.0,
      (top, row) => math.max(top, numberOf(row['power']) ?? 0),
    );
    return CockpitPanel(
      '站所实时负荷',
      groups.isEmpty
          ? empty(liveStatus)
          : Column(
              children: [
                for (final group in groups)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text(
                              '${group['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            child: meter(
                              group['load_percent'] == null
                                  ? (numberOf(group['power']) ?? 0) / limit
                                  : (numberOf(group['load_percent']) ?? 0) /
                                        100,
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
                    ),
                  ),
              ],
            ),
    );
  }

  Widget hourly() {
    final previous = history['yesterday'] as Json? ?? const {};
    final a = valuesOf(today['hours']);
    final b = valuesOf(previous['hours']);
    return CockpitPanel(
      '全网分时耗热',
      a.every((v) => v == null) && b.every((v) => v == null)
          ? empty(historyStatus)
          : CockpitPlot(
              values: a,
              compare: b,
              labels: hours,
              color: mint,
              bars: true,
              showScale: true,
              startAtZero: true,
            ),
      detail: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (today['at'] != null) ...[
            Text(
              '统计至 ${clock(today['at'])}',
              style: const TextStyle(color: dim, fontSize: 12),
            ),
            const SizedBox(width: 18),
          ],
          const Icon(Icons.square_rounded, size: 11, color: mint),
          const SizedBox(width: 5),
          const Text('今日', style: TextStyle(color: dim, fontSize: 13)),
          const SizedBox(width: 13),
          const Icon(Icons.horizontal_rule_rounded, size: 18, color: violet),
          const SizedBox(width: 3),
          const Text('昨日', style: TextStyle(color: dim, fontSize: 13)),
          const SizedBox(width: 14),
          const Text('GJ', style: TextStyle(color: dim, fontSize: 13)),
        ],
      ),
    );
  }

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
    final part = history['zones'] as Json? ?? const {};
    final rows = list(part, 'rows').take(6).toList();
    final maximum = rows
        .expand((r) => valuesOf(r['values']))
        .whereType<double>()
        .fold(1.0, math.max);
    return CockpitPanel(
      '站区分时耗热',
      rows.isEmpty
          ? empty(part['notice']?.toString() ?? historyStatus)
          : Column(
              children: [
                for (final row in rows)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 126,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${row['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, height: 1.1),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final value in valuesOf(row['values']))
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(1),
                                    child: ColoredBox(
                                      color: value == null
                                          ? const Color(0xff101f37)
                                          : Color.lerp(
                                              const Color(0xff173e86),
                                              mint,
                                              (value / maximum).clamp(0.0, 1.0),
                                            )!,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 126, top: 4),
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
              ],
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
              gradient: const LinearGradient(colors: [Color(0xff173e86), mint]),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 7),
          const Text('高 · GJ', style: TextStyle(color: dim, fontSize: 11)),
        ],
      ),
    );
  }

  Widget weekly() {
    final week = history['week'] as Json? ?? const {};
    final metrics = today['metrics'] as Json? ?? const {};
    final labels = [
      if (week['labels'] is List)
        for (final v in week['labels'] as List) '$v',
      if (today['date'] is String) (today['date'] as String).substring(5),
    ];
    final spacedLabels = [
      for (final (i, label) in labels.indexed)
        i == 0 || i == labels.length ~/ 2 || i == labels.length - 1
            ? label
            : '',
    ];
    final groups = [
      ('热量 GJ', 'heat', mint),
      ('用电 kWh', 'electricity', violet),
      ('补水 t', 'water', ice),
    ];
    return CockpitPanel(
      '近7天用量',
      week.isEmpty && metrics.isEmpty
          ? empty(historyStatus)
          : Row(
              children: [
                for (final (i, group) in groups.indexed) ...[
                  if (i > 0)
                    const VerticalDivider(width: 15, color: Color(0xff284667)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.$1,
                          style: TextStyle(color: group.$3, fontSize: 13),
                        ),
                        Expanded(
                          child: CockpitPlot(
                            values: [
                              ...valuesOf(week[group.$2]),
                              if (today['date'] != null)
                                numberOf(metrics[group.$2]),
                            ],
                            labels: spacedLabels,
                            color: group.$3,
                            bars: i == 0,
                            startAtZero: i == 0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget forecast() {
    final days = list(weather, 'daily');
    final hourly = valuesOf(weather['hourly']);
    final outdoor = live['outdoor'] ?? weather['current'];
    final night = weather['night'];
    final labels = weather['labels'] is List
        ? [for (final label in weather['labels'] as List) '$label']
        : <String>[];
    return CockpitPanel(
      '天气预报',
      Column(
        children: [
          SizedBox(
            height: 54,
            child: Row(
              children: [
                const Icon(
                  Icons.nights_stay_rounded,
                  size: 37,
                  color: Color(0xffc9ddff),
                ),
                const SizedBox(width: 10),
                Text(
                  '${reading(outdoor)} °C',
                  style: const TextStyle(
                    fontSize: 31,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (night != null)
                  Text(
                    '今晚最低  ${reading(night)} °C\n预计 ${clock(weather['night_at'])}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: dim, fontSize: 13),
                  ),
              ],
            ),
          ),
          if (hourly.isEmpty)
            Expanded(
              child: empty(
                errors['weather'] ?? weather['notice']?.toString() ?? '正在加载预报',
              ),
            )
          else ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '未来24小时气温',
                style: TextStyle(color: dim, fontSize: 13),
              ),
            ),
            Expanded(
              child: CockpitPlot(
                values: hourly,
                labels: labels,
                dashed: true,
                showScale: true,
              ),
            ),
            if (days.isNotEmpty)
              SizedBox(
                height: 41,
                child: Row(
                  children: [
                    for (final (i, day) in days.take(3).indexed)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              const ['明天', '后天', '大后天'][i],
                              style: const TextStyle(color: dim, fontSize: 12),
                            ),
                            Text(
                              '${reading(day['low'])}° / ${reading(day['high'])}°',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (weather['source'] != null)
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${weather['source']}',
                  style: const TextStyle(color: dim, fontSize: 10),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Color stateColor(Object? state) => switch (state) {
    'online' => mint,
    'delayed' => amber,
    'offline' => const Color(0xffff817d),
    _ => const Color(0xff91a5bf),
  };

  Widget statusGrid() {
    final rows = list(live, 'stations');
    return CockpitPanel(
      '站点在线分布',
      rows.isEmpty
          ? empty(liveStatus)
          : LayoutBuilder(
              builder: (context, box) {
                final count = rows.length;
                final cells = math.max(8, (count / 2).ceil());
                final width = (box.maxWidth - (cells - 1) * 4) / cells;
                return Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final (i, row) in rows.indexed)
                      Semantics(
                        label: '${row['name']} ${stateLabel(row['state'])}',
                        child: Container(
                          width: width,
                          height: 17,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: stateColor(
                              row['state'],
                            ).withValues(alpha: .18),
                            border: Border.all(
                              color: stateColor(
                                row['state'],
                              ).withValues(alpha: .7),
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: stateColor(row['state']),
                              fontSize: 11,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
      detail: const Text(
        '在线 · 延迟 · 离线',
        style: TextStyle(color: dim, fontSize: 11),
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
        .take(3);
    return CockpitPanel(
      '运行关注',
      rows.isEmpty
          ? empty(all.isEmpty ? liveStatus : '当前没有延迟或离线站点')
          : Column(
              children: [
                for (final row in rows)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: stateColor(row['state']),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${row['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          stateLabel(row['state']),
                          style: TextStyle(color: stateColor(row['state'])),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${(numberOf(row['age']) ?? 0) ~/ 60} 分钟',
                          style: const TextStyle(color: dim),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget liveRows() {
    final rows = list(live, 'rows').take(4).toList();
    final trends = history['trends'] as Json? ?? const {};
    const headers = [
      '重点站区',
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
    return CockpitPanel(
      '重点站实时工况',
      rows.isEmpty
          ? empty(liveStatus)
          : Column(
              children: [
                SizedBox(
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
                for (final (ri, row) in rows.indexed)
                  Expanded(
                    child: ColoredBox(
                      color: ri.isEven
                          ? const Color(0xff102847)
                          : Colors.transparent,
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
                              child:
                                  valuesOf(
                                    trends[row['zone']],
                                  ).every((v) => v == null)
                                  ? const Text(
                                      '—',
                                      style: TextStyle(color: dim),
                                    )
                                  : CockpitPlot(
                                      values: valuesOf(trends[row['zone']]),
                                      color: mint,
                                      grid: false,
                                    ),
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
}
