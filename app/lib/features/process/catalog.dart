import 'dart:convert';
import 'package:flutter/services.dart';
import '../../shared/api.dart';

class ProcessSymbol {
  const ProcessSymbol(this.id, this.name, this.category, this.path);
  final String id, name, category, path;
  static Future<List<ProcessSymbol>> load() async {
    final data =
        jsonDecode(await rootBundle.loadString('assets/process/catalog.json'))
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
    return list;
  }
}

final processSymbols = ProcessSymbol.load();
