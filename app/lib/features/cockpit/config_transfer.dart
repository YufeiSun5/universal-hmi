import 'dart:convert';
import 'dart:typed_data';

import '../../shared/api.dart';

const _format = 'hmi-heating-cockpit';

Uint8List encodeCockpitConfig(Json config) {
  final document = {
    'format': _format,
    'version': 1,
    'config': {...config}..remove('revision'),
  };
  final text = const JsonEncoder.withIndent('  ').convert(document);
  return Uint8List.fromList(utf8.encode('$text\n'));
}

Json decodeCockpitConfig(Uint8List bytes) {
  final Object? document;
  try {
    document = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const FormatException('文件不是有效的 UTF-8 JSON');
  }
  if (document case {
    'format': _format,
    'version': 1,
    'config': final Json config,
  }) {
    if (config
        case {
          'title': String _,
          'energy_screen': String _,
          'delay_minutes': int _,
          'offline_minutes': int _,
          'latitude': final latitude,
          'longitude': final longitude,
          'focus_rows': List focus,
          'power_rows': List power,
          'zone_codes': Map zones,
          'rated_mw': Map rated,
        }
        when (latitude == null || latitude is num && latitude.isFinite) &&
            (longitude == null || longitude is num && longitude.isFinite) &&
            _uniqueIds(focus) &&
            _uniqueIds(power) &&
            zones.entries.every(
              (entry) => focus.contains(entry.key) && entry.value is String,
            ) &&
            rated.values.every((value) => value is num && value.isFinite) &&
            _rankNamesValid(config['rank_names']) &&
            _rankAreaValid(config['rank_area_m2'])) {
      return config;
    }
    throw const FormatException('驾驶舱配置字段缺失或格式有误');
  }
  throw const FormatException('请选择本系统导出的驾驶舱配置 JSON（版本 1）');
}

bool _uniqueIds(List rows) =>
    rows.every((id) => id is String && id.isNotEmpty) &&
    rows.toSet().length == rows.length;

bool _rankNamesValid(Object? names) =>
    names == null ||
    names is Map<String, dynamic> &&
        names.length <= 256 &&
        names.entries.every(
          (entry) =>
              RegExp(r'^\d{2}-\d{3}$').hasMatch(entry.key) &&
              entry.value is String &&
              (entry.value as String).trim().isNotEmpty &&
              (entry.value as String).trim().runes.length <= 24 &&
              !(entry.value as String).contains(RegExp(r'[\x00\r\n]')),
        );

bool _rankAreaValid(Object? areas) =>
    areas == null ||
    areas is Map<String, dynamic> &&
        areas.length <= 8 &&
        areas.entries.every(
          (entry) =>
              RegExp(r'^\d{2}-\d{3}$').hasMatch(entry.key) &&
              entry.value is num &&
              (entry.value as num).isFinite &&
              (entry.value as num) > 0,
        );
