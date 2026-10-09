import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../shared/api.dart';

String screenIdentity() => List.generate(
  16,
  (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
double _number(Json data, String key, double fallback) =>
    (data[key] as num?)?.toDouble() ?? fallback;

class ScreenElement {
  ScreenElement(Json data) : data = Map.unmodifiable(data);
  factory ScreenElement.create(
    String kind,
    Offset position, {
    String symbol = '',
    String image = '',
  }) => ScreenElement({
    'id': screenIdentity(),
    'kind': kind,
    'x': position.dx,
    'y': position.dy,
    'width': kind == 'value'
        ? 180.0
        : kind == 'text'
        ? 200.0
        : 100.0,
    'height': kind == 'value' || kind == 'text' ? 44.0 : 100.0,
    'rotation': 0,
    'text': kind == 'text' ? '文字' : '',
    'symbol': symbol,
    'image': image,
    'color': '#2563eb',
    'fill': 'none',
    'stroke_width': 4.0,
    'font_size': 20.0,
    'point_id': '',
    'decimals': 1,
    'show_unit': true,
    'unit_override': '',
    'arrow': true,
    'orthogonal': false,
    'points': <Json>[],
    'start_node': '',
    'start_port': '',
    'end_node': '',
    'end_port': '',
  });
  final Json data;
  String get id => data['id'] as String;
  String get kind => data['kind'] as String;
  double get x => _number(data, 'x', 0);
  double get y => _number(data, 'y', 0);
  double get width => _number(data, 'width', 100);
  double get height => _number(data, 'height', 100);
  Rect get rect => Rect.fromLTWH(x, y, width, height);
  int get rotation => (data['rotation'] as num?)?.toInt() ?? 0;
  String get text => data['text'] as String? ?? '';
  String get symbol => data['symbol'] as String? ?? '';
  String get image => data['image'] as String? ?? '';
  String get pointID => data['point_id'] as String? ?? '';
  int get decimals => (data['decimals'] as num?)?.toInt() ?? 1;
  bool get showUnit => data['show_unit'] == true;
  String get unitOverride => data['unit_override'] as String? ?? '';
  bool get arrow => data['arrow'] == true;
  bool get orthogonal => data['orthogonal'] == true;
  double get strokeWidth => _number(data, 'stroke_width', 4);
  double get fontSize => _number(data, 'font_size', 20);
  Color get color => parseColor(data['color'] as String? ?? '#2563eb');
  Color? get fill => data['fill'] == 'none'
      ? null
      : parseColor(data['fill'] as String? ?? '#ffffff');
  String get startNode => data['start_node'] as String? ?? '';
  String get endNode => data['end_node'] as String? ?? '';
  String get startPort => data['start_port'] as String? ?? '';
  String get endPort => data['end_port'] as String? ?? '';
  List<Offset> get points => objects(
    data['points'],
  ).map((p) => Offset(_number(p, 'x', 0), _number(p, 'y', 0))).toList();
  ScreenElement update(Json changes) => ScreenElement({...data, ...changes});
  ScreenElement withPoints(List<Offset> points, {Json changes = const {}}) {
    final bounds = points.fold<Rect>(
      Rect.fromCircle(center: points.first, radius: 0),
      (r, p) => r.expandToInclude(Rect.fromCircle(center: p, radius: 0)),
    );
    return update({
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
      'points': [
        for (final p in points) {'x': p.dx, 'y': p.dy},
      ],
      ...changes,
    });
  }

  ScreenElement moved(Offset delta) => kind == 'pipe'
      ? withPoints(
          points.map((p) => p + delta).toList(),
          changes: {
            'start_node': '',
            'start_port': '',
            'end_node': '',
            'end_port': '',
          },
        )
      : update({'x': x + delta.dx, 'y': y + delta.dy});
}

Color parseColor(String value) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    throw const FormatException('颜色必须为 #RRGGBB');
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

String colorHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

class EmbeddedImage {
  EmbeddedImage(this.name, this.mime, this.data);
  factory EmbeddedImage.fromJson(Json data) => EmbeddedImage(
    data['name'] as String,
    data['mime'] as String,
    data['data'] as String,
  );
  final String name, mime, data;
  late final Uint8List bytes = base64Decode(data);
  Json toJson() => {'name': name, 'mime': mime, 'data': data};
}

class ScreenDocument {
  ScreenDocument({
    required this.id,
    required this.name,
    required this.station,
    this.revision = 0,
    this.width = 1600,
    this.height = 900,
    List<ScreenElement> nodes = const [],
    Map<String, EmbeddedImage> assets = const {},
  }) : nodes = List.unmodifiable(nodes),
       assets = Map.unmodifiable(assets);
  factory ScreenDocument.empty(String station) =>
      ScreenDocument(id: screenIdentity(), name: '未命名工艺画面', station: station);
  factory ScreenDocument.fromJson(Json data) {
    if (data['schema_version'] != 1) throw const FormatException('不支持的工艺画面版本');
    final document = ScreenDocument(
      id: data['id'] as String,
      name: data['name'] as String,
      station: data['station'] as String,
      revision: (data['revision'] as num).toInt(),
      width: (data['width'] as num).toDouble(),
      height: (data['height'] as num).toDouble(),
      nodes: objects(data['nodes']).map(ScreenElement.new).toList(),
      assets: (data['assets'] as Map? ?? {}).map(
        (k, v) => MapEntry(
          k as String,
          EmbeddedImage.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      ),
    );
    document.checkGeometry();
    return document;
  }
  final String id, name, station;
  final int revision;
  final double width, height;
  final List<ScreenElement> nodes;
  final Map<String, EmbeddedImage> assets;
  ScreenDocument copy({
    String? id,
    String? name,
    String? station,
    int? revision,
    double? width,
    double? height,
    List<ScreenElement>? nodes,
    Map<String, EmbeddedImage>? assets,
  }) => ScreenDocument(
    id: id ?? this.id,
    name: name ?? this.name,
    station: station ?? this.station,
    revision: revision ?? this.revision,
    width: width ?? this.width,
    height: height ?? this.height,
    nodes: nodes ?? this.nodes,
    assets: assets ?? this.assets,
  );
  ScreenDocument instantiate(String target, {String suffix = ' 副本'}) => copy(
    id: screenIdentity(),
    revision: 0,
    station: target,
    name: '$name$suffix',
    nodes: target == station
        ? nodes
        : [
            for (final n in nodes) n.update({'point_id': ''}),
          ],
  );
  Json toJson() => {
    'schema_version': 1,
    'id': id,
    'revision': revision,
    'name': name,
    'station': station,
    'width': width,
    'height': height,
    'nodes': [for (final n in nodes) n.data],
    'assets': assets.map((k, v) => MapEntry(k, v.toJson())),
  };
  void checkGeometry() {
    if (!width.isFinite ||
        !height.isFinite ||
        width < 320 ||
        height < 240 ||
        width > 8192 ||
        height > 8192 ||
        nodes.length > 1000 ||
        assets.length > 64) {
      throw const FormatException('画布或元素数量超出限制');
    }
    final ids = <String>{};
    for (final n in nodes) {
      if (!ids.add(n.id) ||
          !{
            'pipe',
            'symbol',
            'image',
            'text',
            'value',
            'rect',
            'ellipse',
          }.contains(n.kind) ||
          [
            n.x,
            n.y,
            n.width,
            n.height,
            n.fontSize,
            n.strokeWidth,
          ].any((v) => !v.isFinite) ||
          n.x < 0 ||
          n.y < 0 ||
          n.width < 0 ||
          n.height < 0 ||
          n.x + n.width > width ||
          n.y + n.height > height ||
          n.fontSize < 8 ||
          n.fontSize > 128 ||
          n.strokeWidth < 1 ||
          n.strokeWidth > 32 ||
          n.decimals < 0 ||
          n.decimals > 6 ||
          !{0, 90, 180, 270}.contains(n.rotation) ||
          n.text.length > 4096 ||
          n.unitOverride.length > 64) {
        throw const FormatException('工艺画面元素无效');
      }
      parseColor(n.data['color'] as String);
      if (n.data['fill'] != 'none') parseColor(n.data['fill'] as String);
      if (n.kind == 'pipe' &&
          (n.points.length < 2 ||
              n.points.length > 256 ||
              n.points.any(
                (p) =>
                    !p.dx.isFinite ||
                    !p.dy.isFinite ||
                    p.dx < 0 ||
                    p.dy < 0 ||
                    p.dx > width ||
                    p.dy > height,
              ))) {
        throw const FormatException('管道节点无效');
      }
      if (n.kind != 'pipe' && (n.width < 8 || n.height < 8)) {
        throw const FormatException('元素尺寸过小');
      }
      if (n.kind == 'image' && !assets.containsKey(n.image)) {
        throw const FormatException('图片未嵌入');
      }
    }
    for (final image in assets.values) {
      if (!{'image/png', 'image/jpeg'}.contains(image.mime) ||
          image.data.length > 2796204 ||
          image.bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('图片仅支持 PNG/JPEG，单张不超过 2 MiB');
      }
    }
  }

  Offset port(String id, String side) {
    final n = nodes.where((n) => n.id == id).firstOrNull;
    if (n == null) return Offset.zero;
    return switch (side) {
      'left' => n.rect.centerLeft,
      'right' => n.rect.centerRight,
      'top' => n.rect.topCenter,
      'bottom' => n.rect.bottomCenter,
      _ => n.rect.center,
    };
  }

  List<Offset> pipePoints(ScreenElement n) {
    final result = n.points;
    if (n.startNode.isNotEmpty && nodes.any((e) => e.id == n.startNode)) {
      final original = result.first, target = port(n.startNode, n.startPort);
      result[0] = target;
      if (result.length > 2) {
        result[1] =
            (result[1].dx - original.dx).abs() <
                (result[1].dy - original.dy).abs()
            ? Offset(target.dx, result[1].dy)
            : Offset(result[1].dx, target.dy);
      }
    }
    if (n.endNode.isNotEmpty && nodes.any((e) => e.id == n.endNode)) {
      final last = result.length - 1,
          original = result[last],
          target = port(n.endNode, n.endPort);
      result[last] = target;
      if (result.length > 2) {
        result[last - 1] =
            (result[last - 1].dx - original.dx).abs() <
                (result[last - 1].dy - original.dy).abs()
            ? Offset(target.dx, result[last - 1].dy)
            : Offset(result[last - 1].dx, target.dy);
      }
    }
    if (!n.orthogonal) return result;
    final routed = <Offset>[result.first];
    for (final target in result.skip(1)) {
      final previous = routed.last;
      if (previous.dx != target.dx && previous.dy != target.dy) {
        routed.add(Offset(target.dx, previous.dy));
      }
      if (target != routed.last) routed.add(target);
    }
    return routed.length >= 2 ? routed : [routed.first, routed.first];
  }
}

class ProcessValue {
  const ProcessValue(this.text, this.quality, this.active, this.tooltip);
  final String text, quality, tooltip;
  final bool active;
  bool get good => quality == 'good';
}

ProcessValue processValue(
  ScreenElement node,
  ScreenDocument document,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  if (node.pointID.isEmpty) {
    return const ProcessValue('未绑定', 'unbound', false, '请选择实时点位');
  }
  final definition = definitions[node.pointID], sample = live[node.pointID];
  var quality = !online
      ? 'offline'
      : definition == null
      ? 'missing'
      : document.station.isNotEmpty && definition['station'] != document.station
      ? 'scope'
      : sample?['quality']?.toString() ?? 'missing';
  final value = sample?['value'];
  if (quality == 'good' && (value == null || value is num && !value.isFinite)) {
    quality = 'missing';
  }
  if (quality == 'good' &&
      node.kind != 'value' &&
      value is! num &&
      value is! bool) {
    quality = 'unsupported';
  }
  const labels = {
    'good': '正常',
    'bad': '坏质量',
    'stale': '陈旧',
    'missing': '缺失',
    'offline': '离线',
    'scope': '站点已变更',
    'uncertain': '不确定',
    'unsupported': '状态类型不支持',
  };
  final label = labels[quality] ?? '质量未知';
  final raw = value is num
      ? value.toStringAsFixed(node.decimals)
      : value == true
      ? '1'
      : value == false
      ? '0'
      : value?.toString() ?? '—';
  final unit = node.showUnit
      ? node.unitOverride.isNotEmpty
            ? node.unitOverride
            : (sample?['unit'] ?? definition?['unit'] ?? '').toString()
      : '';
  final text = quality == 'good'
      ? '${node.text}$raw${unit.isEmpty ? '' : ' $unit'}'
      : '— $label';
  return ProcessValue(
    text,
    quality,
    quality == 'good' && (value == true || value is num && value != 0),
    '${definition?['name'] ?? node.pointID}\n点位 ID：${node.pointID}\n质量：$label\n源时间：${sample?['source_time'] ?? '—'}\n接收时间：${sample?['received_time'] ?? '—'}',
  );
}
