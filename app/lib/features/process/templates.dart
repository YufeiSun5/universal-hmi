import 'dart:convert';
import 'package:flutter/services.dart';
import '../../shared/api.dart';
import 'model.dart';

class ProcessTemplate {
  const ProcessTemplate(this.id, this.name, this.description, this.load);
  final String id, name, description;
  final Future<ScreenDocument> Function(String station) load;
}

class ProcessTemplates {
  static final catalog = <ProcessTemplate>[
    ProcessTemplate(
      'blank',
      '空白工艺画面',
      '从空白画布开始，自由添加设备和管道。',
      (station) async =>
          ScreenDocument(id: screenIdentity(), name: '', station: station),
    ),
    ProcessTemplate(
      'heating',
      '深蓝供热工艺示例',
      '深蓝监视布局，包含供回水、换热设备及变量占位。',
      heatingMonitor,
    ),
    ProcessTemplate(
      'heating-basic',
      '三换热器工艺示例',
      '三组换热器基础布局，可继续编辑设备与管道。',
      heatingStation,
    ),
    for (final entry in const [
      ('branch-three', '分支计量 · 三泵', '二次供水双支路分别计量，三组循环泵读数。'),
      ('single-three', '单路计量 · 三泵', '二次供水单路计量，三组循环泵读数。'),
      ('single-two', '单路计量 · 双泵', '二次供水单路计量，两组循环泵及读数。'),
      ('single-one', '单路计量 · 单泵', '二次供水单路计量，一组循环泵读数。'),
      ('series-one', '双表串联 · 单泵', '二次供水两表串联，一组循环泵读数。'),
    ])
      ProcessTemplate(
        'heating-${entry.$1}',
        entry.$2,
        entry.$3,
        (station) => _variant(entry.$1, station),
      ),
  ];
  static Future<ScreenDocument> _variant(String slug, String station) async {
    final json =
        jsonDecode(
              await rootBundle.loadString(
                'assets/process/templates/heating-$slug.json',
                cache: false,
              ),
            )
            as Json;
    return ScreenDocument.fromJson(json).instantiate(station, suffix: '');
  }

  static Json? _heating;
  static Json? _monitor;
  static Future<ScreenDocument> heatingMonitor(String station) async {
    final json = _monitor ??=
        jsonDecode(
              await rootBundle.loadString(
                'assets/process/templates/heating-monitor.json',
                cache: false,
              ),
            )
            as Json;
    return ScreenDocument.fromJson(json).instantiate(station, suffix: '');
  }

  static Future<ScreenDocument> heatingStation(String station) async {
    final json = _heating ??=
        jsonDecode(
              await rootBundle.loadString(
                'assets/process/templates/heating-station.json',
                cache: false,
              ),
            )
            as Json;
    return ScreenDocument.fromJson(json).instantiate(station, suffix: '');
  }
}
