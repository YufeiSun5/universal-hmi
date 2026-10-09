import 'dart:convert';
import 'package:flutter/services.dart';
import '../../shared/api.dart';

class ProcessSymbol {
  const ProcessSymbol(
    this.id,
    this.name,
    this.category,
    this.path, {
    this.tintable = true,
  });
  final String id, name, category, path;
  final bool tintable;
  static List<ProcessSymbol>? _loaded;
  static Future<List<ProcessSymbol>> load() async {
    if (_loaded != null) return _loaded!;
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/process/catalog.json',
                cache: false,
              ),
            )
            as Map;
    final list = objects(data['items'])
        .map(
          (s) => ProcessSymbol(
            s['id'] as String,
            s['name'] as String,
            s['category'] as String,
            s['path'] as String,
          ),
        )
        .toList();
    list.addAll(const [
      ProcessSymbol(
        'example_plate_hx',
        '板式换热器',
        '示例设备',
        'assets/process/examples/plate-hx.svg',
        tintable: false,
      ),
      ProcessSymbol(
        'example_pump',
        '循环泵',
        '示例设备',
        'assets/process/examples/pump.svg',
        tintable: false,
      ),
      ProcessSymbol(
        'example_tank',
        '补水箱',
        '示例设备',
        'assets/process/examples/tank.svg',
        tintable: false,
      ),
      ProcessSymbol(
        'example_valve',
        '调节阀',
        '示例设备',
        'assets/process/examples/valve.svg',
        tintable: false,
      ),
    ]);
    const priority = [
      '换热器',
      '泵',
      '泵 DIN',
      '泵 ISO',
      '阀门',
      '容器与水箱',
      '流量仪表',
      '仪表',
      '管道',
      '管件',
    ];
    int rank(String c) {
      final n = priority.indexOf(c);
      return n < 0 ? 100 : n;
    }

    list.sort((a, b) {
      final r = rank(a.category).compareTo(rank(b.category));
      return r != 0
          ? r
          : '${a.category}${a.name}'.compareTo('${b.category}${b.name}');
    });
    return _loaded = List.unmodifiable(list);
  }
}

Future<List<ProcessSymbol>> get processSymbols => ProcessSymbol.load();
