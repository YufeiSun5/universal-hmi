import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../platform/external_link.dart';
import '../../shared/api.dart';
import 'charts.dart';
import 'heat_rate.dart';
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
                    SizedBox(height: 74, child: kpis()),
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
                                Expanded(flex: 70, child: forecast()),
                                const SizedBox(height: 9),
                                Expanded(flex: 30, child: stationStatus()),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(height: 218, child: liveRows()),
                    if (weather['source'] == '和风天气')
                      const _WeatherAttribution(),
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

  double? dailyMetric(String key) {
    final totals = today['metrics'] as Json? ?? const {};
    final subtotals = today['partial_metrics'] as Json? ?? const {};
    return numberOf(totals[key]) ?? numberOf(subtotals[key]);
  }

  Widget kpis() {
    final stations = list(live, 'stations');
    final online = stations.where((s) => s['state'] == 'online').length;
    final heat = dailyMetric('heat');
    final electricity = dailyMetric('electricity');
    final water = dailyMetric('water');
    final items = [
      (
        '实时供热功率',
        reading(heatRateFromMW(numberOf(live['power'])), 1),
        heatRateUnit,
        Icons.waves_rounded,
        ice,
      ),
      (
        '今日中节能耗热',
        reading(heat),
        'GJ',
        Icons.local_fire_department_outlined,
        mint,
      ),
      ('今日用电', reading(electricity), 'kWh', Icons.bolt_rounded, violet),
      ('今日补水', reading(water, 1), 't', Icons.water_drop_outlined, ice),
      (
        '在线站数',
        stations.isEmpty ? '—' : '$online/${stations.length}',
        '',
        Icons.circle_outlined,
        mint,
      ),
    ];
    return DecoratedBox(
      key: const ValueKey('cockpit-kpis'),
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
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i == 4)
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            value: stations.isEmpty
                                ? 0
                                : online / stations.length,
                            strokeWidth: 5,
                            color: mint,
                            backgroundColor: const Color(0xff375475),
                          ),
                        )
                      else
                        Icon(
                          items[i].$4,
                          size: 32,
                          color: items[i].$5,
                          shadows: [
                            Shadow(
                              color: items[i].$5.withValues(alpha: .45),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      const SizedBox(width: 13),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            items[i].$1,
                            style: const TextStyle(color: dim, height: 1.15),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                items[i].$2,
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  height: 1.05,
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
              ),
            ),
          ],
        ],
      ),
    );
  }

  String heatStationName(Json row) {
    final names = history['rank_names'] as Json? ?? const {};
    return (names[row['id']] ?? row['name']).toString();
  }

  Widget ranking() {
    final all = list(history, 'rank_per_area');
    final peak = numberOf(all.firstOrNull?['value']) ?? 0;
    final limit = peak > 0 ? peak : 1.0;
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
                style: TextStyle(color: index == 0 ? mint : ice, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 154,
              child: Text(
                heatStationName(row),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(child: meter((numberOf(row['value']) ?? 0) / limit, mint)),
            const SizedBox(width: 8),
            SizedBox(
              width: 73,
              child: Text(reading(row['value'], 5), textAlign: TextAlign.right),
            ),
            SizedBox(
              width: 65,
              child: Text(
                row['value'] == null ? '—' : delta('${row['id']}'),
                textAlign: TextAlign.right,
                style: const TextStyle(color: dim, fontSize: 13),
              ),
            ),
          ],
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '中节能单位面积耗热排行',
          all.isEmpty ? empty('—') : body,
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
                            ? '今日 GJ/㎡  /  较昨同期至 $cutoff'
                            : '今日 GJ/㎡  /  较昨日同期',
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
                width: 139,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${reading(heatRateFromMW(numberOf(group['power'])), 1)} $heatRateUnit'
                    '${group['load_percent'] == null ? '' : ' · ${reading(group['load_percent'])}%'}',
                    style: const TextStyle(
                      color: ice,
                      fontWeight: FontWeight.w600,
                    ),
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
    List<double?> available(Json day) {
      final complete = valuesOf(day['hours']);
      final partial = valuesOf(day['partial_hours']);
      return [
        for (var i = 0; i < math.max(complete.length, partial.length); i++)
          complete.elementAtOrNull(i) ?? partial.elementAtOrNull(i),
      ];
    }

    final shown = available(today);
    final yesterday = available(previous);
    final latest = shown.lastIndexWhere((value) => value != null);
    String hourLabel(int hour) => '${hour.toString().padLeft(2, '0')}:00';
    final closed = (today['closed_hours'] as num?)?.toInt();
    final plotExists = latest >= 0 || yesterday.any((value) => value != null);
    return CockpitPanel(
      '中节能分时耗热',
      plotExists
          ? CockpitPlot(
              values: shown,
              compare: yesterday,
              labels: hours,
              color: mint,
              bars: true,
              showScale: true,
              startAtZero: true,
            )
          : empty('—'),
      detail: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (closed != null) ...[
            Text(
              '今日至 ${hourLabel(closed)}',
              style: const TextStyle(color: dim, fontSize: 12),
            ),
            const SizedBox(width: 16),
          ],
          const Icon(Icons.square_rounded, size: 11, color: mint),
          const SizedBox(width: 5),
          const Text('今日', style: TextStyle(color: dim, fontSize: 13)),
          const SizedBox(width: 12),
          const Icon(Icons.horizontal_rule_rounded, size: 17, color: violet),
          const SizedBox(width: 3),
          const Text('昨日', style: TextStyle(color: dim, fontSize: 13)),
          const SizedBox(width: 14),
          const Text('GJ', style: TextStyle(color: dim, fontSize: 13)),
        ],
      ),
      pinnedFooter: latest < 0
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '今日 ${hourLabel(latest)}–${hourLabel(latest + 1)}  ${reading(shown[latest], 1)} GJ',
                  style: const TextStyle(color: dim, fontSize: 12),
                ),
              ),
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
    const nameWidth = 160.0;
    final stationHours = today['station_hours'] as Json? ?? const {};
    final rows = [...list(today, 'ranking')]
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final series = [for (final row in rows) valuesOf(stationHours[row['id']])];
    final maximum = series
        .expand((values) => values)
        .whereType<double>()
        .fold(1.0, math.max);
    final filledColumns = series.fold(
      0,
      (count, values) =>
          math.max(count, values.lastIndexWhere((value) => value != null) + 1),
    );
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
                    heatStationName(row),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              Expanded(
                child: HeatmapCells(
                  values: series[index],
                  maximum: maximum,
                  phase: phase,
                  filledColumns: filledColumns,
                ),
              ),
            ],
          );
        },
        buildPanel: (body, range) {
          return CockpitPanel(
            '中节能各站分时耗热',
            rows.isEmpty ? empty('—') : body,
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
                    gradient: const LinearGradient(colors: [heatLow, heatHigh]),
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
      ('中节能耗热量', 'GJ', 'heat', mint, 0),
      ('用电量', 'kWh', 'electricity', violet, 0),
      ('补水量', 't', 'water', ice, 1),
    ];
    return CockpitPanel(
      '近7天用量',
      week.isEmpty && today.isEmpty
          ? empty('—')
          : Row(
              children: [
                for (final (i, group) in groups.indexed) ...[
                  if (i > 0)
                    const VerticalDivider(width: 22, color: Color(0xff284667)),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final current = dailyMetric(group.$3);
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
                                  ? empty('—')
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
      detail: week.isEmpty && today.isEmpty
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
            height: 64,
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
                  condition.isEmpty ? '外部实况' : '外部实况 · $condition',
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
              height: 48,
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
            : null,
      ),
    );
  }

  Color stateColor(Object? state) => switch (state) {
    'online' => mint,
    'delayed' => violet,
    'offline' => const Color(0xffff817d),
    _ => const Color(0xff91a5bf),
  };

  Widget stationStatus() {
    final stations = list(live, 'stations');
    Widget statusRow(Json row) {
      final name = row['name'].toString();
      final color = stateColor(row['state']);
      final label = switch (row['state']) {
        'online' => '在线',
        'delayed' => '延迟',
        'offline' => '离线',
        _ => '未采样',
      };
      final age = numberOf(row['age']);
      final status =
          age != null &&
              (row['state'] == 'delayed' || row['state'] == 'offline')
          ? '$label ${age < 60 ? '<1' : age ~/ 60}分'
          : label;
      return Semantics(
        container: true,
        excludeSemantics: true,
        label: '$name $status',
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
            Text(status, style: TextStyle(color: color, fontSize: 13)),
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
      '近2小时热功率（$heatRateUnit）',
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
        final trend = valuesOf(
          trends[row['zone']],
        ).map(heatRateFromMW).toList();
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
                    row[key] is! Map
                        ? '—'
                        : key == 'power'
                        ? '${reading(heatRateFromMW(numberOf((row[key] as Map)['value'])), 1)} $heatRateUnit'
                        : '${reading((row[key] as Map)['value'], i == 2 || i == 3 ? 2 : 1)} ${(row[key] as Map)['unit'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                  child: trend.every((v) => v == null)
                      ? const Text('—', style: TextStyle(color: dim))
                      : CockpitPlot(values: trend, color: mint, grid: false),
                ),
              ),
            ],
          ),
        );
      },
      buildPanel: (body, range) {
        return CockpitPanel(
          '二次网站区实时工况',
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

class _WeatherAttribution extends StatelessWidget {
  const _WeatherAttribution();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 19,
    child: Align(
      alignment: Alignment.bottomRight,
      child: Semantics(
        link: true,
        child: InkWell(
          onTap: () => openExternalLink(Uri.https('www.qweather.com', '/')),
          child: const Text(
            '天气数据来源：和风天气',
            style: TextStyle(
              color: dim,
              fontSize: 12,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    ),
  );
}
