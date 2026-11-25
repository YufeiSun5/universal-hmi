import 'dart:math' as math;
import '../../shared/api.dart';

// Compiled only into the local review build.
const cockpitSample = bool.fromEnvironment('HMI_COCKPIT_SAMPLE');

final Map<String, Json> sampleCockpit = cockpitSample
    ? _reviewData()
    : const {};

Map<String, Json> _reviewData() {
  const names = [
    '中心站',
    '新北站',
    '西站',
    '南站',
    '景泰中央公园站',
    '香港广场站',
    '阳光壹佰站',
    '国奥二期站',
    '华府怡景站',
    '北站',
    '国奥首站',
    '国奥一期站',
    '红光美苑站',
    '红光美苑首站',
    '金岳福里站',
    '张屯站',
  ];
  final zoneNames = [
    '中心站东南区',
    '新北站北线',
    '新西站南线',
    '新南站南线',
    for (final name in names.skip(4)) '$name · 主区',
    for (final name in names.take(15)) '$name · 二区',
  ];
  String zone(int i) => 'review-zone-$i';
  const power = [33.6, 24.3, 17.8, 10.7];
  double zonePower(int i) =>
      i < power.length ? power[i] : math.max(3.1, 17.4 - .43 * i);
  List<double> trend(int i) => List.generate(
    48,
    (j) =>
        zonePower(i) +
        j / 25 +
        math.sin(j * .36 + i) * 1.8 +
        math.cos(j * 1.35) * .46,
  );
  double heatUsage(int i) {
    var total = 0.0;
    for (var hour = 0; hour < 16; hour++) {
      total +=
          (21.0 -
              (i % names.length) * .86 +
              7.6 * math.sin((hour - 4) * .23) +
              1.9 * math.sin(hour * .64 + i)) *
          (1 + (i.isEven ? .035 : -.038));
    }
    return total;
  }

  const heatStations = {
    '01-001': 0,
    '01-003': 5,
    '01-005': 8,
    '02-002': 9,
    '02-003': 10,
    '03-001': 2,
    '04-001': 3,
    '04-003': 15,
  };
  final ranking = [
    for (final e in heatStations.entries)
      {'id': e.key, 'name': names[e.value], 'value': heatUsage(e.value)},
  ]..sort((a, b) => (b['value'] as double).compareTo(a['value'] as double));
  Json value(double amount, String unit) => {'value': amount, 'unit': unit};
  return {
    'live': {
      'power': 86.4,
      'outdoor': -3.6,
      'stations': [
        for (var i = 0; i < names.length; i++)
          {
            'name': names[i],
            'state': i == 4
                ? 'delayed'
                : i == 7
                ? 'offline'
                : 'online',
            'age': i == 4
                ? 222
                : i == 7
                ? 428
                : 31,
          },
      ],
      'rows': [
        for (var i = 0; i < zoneNames.length; i++)
          {
            'name': zoneNames[i],
            'zone': zone(i),
            'supply_temp': value(92.6 - (i % 8) * 1.1, '°C'),
            'return_temp': value(56.4 - (i % 8) * .5, '°C'),
            'supply_pressure': value(.82 - (i % 10) * .035, 'MPa'),
            'return_pressure': value(.38 - (i % 10) * .019, 'MPa'),
            'flow': value(812.3 - (i % 8) * 81, 't/h'),
            'power': value(zonePower(i), 'MW'),
          },
      ],
    },
    'history': {
      'unit_rankings': {
        'heat': [
          for (final row in ranking)
            {...row, 'value': (row['value'] as double) / 50000, 'delta': 2.4},
        ],
        'electricity': [
          for (final (i, name) in names.indexed)
            {
              'id': 'energy-$i',
              'name': name,
              'value': .068 - i * .003,
              'delta': i.isEven ? 4.3 : -2.1,
            },
        ],
        'water': [
          for (final (i, name) in names.indexed)
            {
              'id': 'energy-$i',
              'name': name,
              'value': .00047 - i * .000026,
              'delta': i.isEven ? 1.6 : -2.0,
            },
        ],
      },
      'month': {
        'labels': [
          for (var day = 1; day < 19; day++)
            '11-${day.toString().padLeft(2, '0')}',
        ],
        'heat': [
          for (var day = 1; day < 19; day++)
            3660 + 590 * math.sin(day * .71) + 40 * day,
        ],
        'electricity': [
          for (var day = 1; day < 19; day++)
            9100 + 320 * math.cos(day * .64) + 120 * day,
        ],
        'water': [
          for (var day = 1; day < 19; day++)
            104 + 12 * math.cos(day * .81) + day * .25,
        ],
      },
      'today': {
        'date': '2026-11-19',
        'closed_hours': 16,
        'metrics': {
          'heat': ranking.fold<double>(
            0,
            (sum, row) => sum + (row['value'] as double),
          ),
          'electricity': 12630,
          'water': 112,
        },
      },
      'trends': {for (var i = 0; i < zoneNames.length; i++) zone(i): trend(i)},
    },
    'weather': {
      'current': -2.7,
      'condition': '多云',
      'night': -7,
      'night_at': '2026-11-19T20:00:00Z',
      'hourly': [
        -3,
        -3.6,
        -4.2,
        -5,
        -5.5,
        -5.8,
        -6.1,
        -6.4,
        -6.4,
        -6.6,
        -6.8,
        -7,
        -6.7,
        -6.5,
        -6.3,
        -5.8,
        -5.1,
        -4.1,
        -3.6,
        -2.4,
        -1.7,
        -1.2,
        -1.4,
        -1.8,
      ],
      'labels': ['16:00', '22:00', '04:00', '10:00', '15:00'],
      'daily': [
        {'low': -7, 'high': 1, 'condition': '晴'},
        {'low': -5, 'high': 2, 'condition': '多云'},
        {'low': -4, 'high': 3, 'condition': '阴'},
      ],
    },
  };
}
