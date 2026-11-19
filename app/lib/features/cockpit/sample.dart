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
    '新西站',
    '新南站',
    '景泰中央公园站',
    '香港广场站',
    '阳光壹佰站',
    '国奥二期站',
    '华府怡景站',
    '北站三号炉站',
    '国奥首站',
    '国奥一期站',
    '红光美苑站',
    '红光美苑首站',
    '金岳福里站',
    '张屯站',
  ];
  const zones = ['01-001-01', '02-001-01', '03-001-01', '04-001-01'];
  const focus = ['中心站东南区', '新北站北线', '新西站南线', '新南站南线'];
  const power = [33.6, 24.3, 17.8, 10.7];
  List<double> trend(int i) => List.generate(
    48,
    (j) =>
        power[i] +
        j / 25 +
        math.sin(j * .36 + i) * 1.8 +
        math.cos(j * 1.35) * .46,
  );
  List<double?> hourly(int i, bool current) => List.generate(24, (h) {
    if (current && h >= 16) return null;
    return (21.0 -
            i * .86 +
            7.6 * math.sin((h - 4) * .23) +
            1.9 * math.sin(h * .64 + i)) *
        (current ? 1 + (i.isEven ? .035 : -.038) : 1);
  });
  final a = {for (var i = 0; i < names.length; i++) '$i': hourly(i, true)};
  final b = {for (var i = 0; i < names.length; i++) '$i': hourly(i, false)};
  List<double?> total(Map<String, List<double?>> values, int end) =>
      List.generate(
        24,
        (h) => h < end
            ? values.values.fold<double>(0, (sum, row) => sum + (row[h] ?? 0))
            : null,
      );
  Json value(double amount, String unit) => {'value': amount, 'unit': unit};
  return {
    'live': {
      'power': 86.4,
      'outdoor': -3,
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
      'groups': [
        for (var i = 0; i < power.length; i++)
          {'name': names[i], 'power': power[i]},
      ],
      'rows': [
        for (var i = 0; i < focus.length; i++)
          {
            'name': focus[i],
            'zone': zones[i],
            'supply_temp': value(92.6 - i * 1.1, '°C'),
            'return_temp': value(56.4 - i * .5, '°C'),
            'supply_pressure': value(.82 - i * .035, 'MPa'),
            'return_pressure': value(.38 - i * .019, 'MPa'),
            'flow': value(812.3 - i * 129, 't/h'),
            'power': value(power[i], 'MW'),
          },
      ],
    },
    'history': {
      'today': {
        'at': '2026-11-19T08:00:00Z',
        'date': '2026-11-19',
        'closed_hours': 16,
        'metrics': {'heat': 4286, 'electricity': 12630, 'water': 112},
        'hours': total(a, 16),
        'station_hours': a,
        'ranking': [
          for (var i = 0; i < 8; i++)
            {'id': '$i', 'name': names[i], 'value': 551.5 - i * 52.2},
        ],
      },
      'yesterday': {'hours': total(b, 24), 'station_hours': b},
      'week': {
        'labels': ['11-13', '11-14', '11-15', '11-16', '11-17', '11-18'],
        'heat': [3430, 3340, 3910, 4280, 4130, 3985],
        'electricity': [10942, 10924, 11292, 12081, 11532, 12174],
        'water': [109, 93, 98, 110, 106, 101],
      },
      'zones': {
        'rows': [
          for (var i = 0; i < focus.length; i++)
            {'name': focus[i], 'values': hourly(i, true)},
          {'name': '景泰中央公园高区', 'values': hourly(5, true)},
          {'name': '香港广场站区', 'values': hourly(6, true)},
        ],
      },
      'trends': {for (var i = 0; i < zones.length; i++) zones[i]: trend(i)},
    },
    'weather': {
      'current': -3,
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
      'labels': ['16:00', '22:00', '04:00', '10:00', '16:00'],
      'daily': [
        {'low': -7, 'high': 1},
        {'low': -5, 'high': 2},
        {'low': -4, 'high': 3},
      ],
    },
  };
}
