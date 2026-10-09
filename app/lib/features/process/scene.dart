import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../shared/api.dart';
import 'catalog.dart';
import 'model.dart';

/// Drawing only: the editor and embedded component use exactly the same scene.
class ProcessScene extends StatelessWidget {
  const ProcessScene({
    super.key,
    required this.document,
    required this.symbols,
    required this.definitions,
    required this.live,
    required this.online,
    this.overlays = const [],
  });
  final ScreenDocument document;
  final Map<String, ProcessSymbol> symbols;
  final Map<String, Json> definitions, live;
  final bool online;
  final List<Widget> overlays;
  Color stateColor(ScreenElement n) {
    if (n.pointID.isEmpty) return n.color;
    final state = processValue(n, document, definitions, live, online);
    return state.good
        ? state.active
              ? n.color
              : const Color(0xff94a3b8)
        : state.quality == 'bad'
        ? const Color(0xffdc2626)
        : const Color(0xffb7791f);
  }

  Widget element(ScreenElement n) {
    final value = processValue(n, document, definitions, live, online);
    final symbol = symbols[n.symbol];
    final color = stateColor(n);
    Widget content = switch (n.kind) {
      'symbol' =>
        symbol == null
            ? const Center(child: Text('素材缺失'))
            : SvgPicture.asset(
                symbol.path,
                colorFilter: symbol.tintable
                    ? ColorFilter.mode(color, BlendMode.srcIn)
                    : null,
              ),
      'image' =>
        document.assets[n.image] == null
            ? const Center(child: Text('图片缺失'))
            : Image.memory(
                document.assets[n.image]!.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Center(child: Text('图片无法读取')),
              ),
      'value' => Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value.text,
            key: Key('process-value-${n.id}'),
            maxLines: 1,
            style: TextStyle(
              fontSize: n.fontSize,
              color: value.good ? n.color : const Color(0xffb7791f),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      'text' => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          n.text,
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: n.fontSize, color: n.color),
        ),
      ),
      _ => CustomPaint(painter: _ShapePainter(n, color)),
    };
    if (n.rotation != 0) {
      content = RotatedBox(quarterTurns: n.rotation ~/ 90, child: content);
    }
    if (n.kind == 'symbol' && n.pointID.isNotEmpty && !value.good) {
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: const Color(0xe6ffffff),
              child: Text(
                value.text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xffb7791f)),
              ),
            ),
          ),
        ],
      );
    }
    return Positioned(
      left: n.x,
      top: n.y,
      width: n.width,
      height: n.height,
      child: Tooltip(
        message: n.pointID.isNotEmpty
            ? value.tooltip
            : n.text.isNotEmpty
            ? n.text
            : symbol?.name ?? n.kind,
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.hardEdge,
    children: [
      const Positioned.fill(child: ColoredBox(color: Colors.white)),
      for (final n in document.nodes)
        if (n.kind == 'pipe')
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: ProcessPipePainter(
                  document.pipePoints(n),
                  stateColor(n),
                  n.strokeWidth,
                  n.arrow,
                ),
                child:
                    n.pointID.isNotEmpty &&
                        !processValue(
                          n,
                          document,
                          definitions,
                          live,
                          online,
                        ).good
                    ? Stack(
                        children: [
                          Positioned(
                            left: document.pipePoints(n).first.dx,
                            top: document.pipePoints(n).first.dy + 5,
                            child: Text(
                              processValue(
                                n,
                                document,
                                definitions,
                                live,
                                online,
                              ).text,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xffb7791f),
                              ),
                            ),
                          ),
                        ],
                      )
                    : null,
              ),
            ),
          )
        else
          element(n),
      ...overlays,
    ],
  );
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.node, this.color);
  final ScreenElement node;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(node.strokeWidth / 2);
    final p = Paint();
    if (node.fill != null) {
      p.color = node.fill!;
      node.kind == 'ellipse'
          ? canvas.drawOval(rect, p)
          : canvas.drawRect(rect, p);
    }
    p
      ..color = color
      ..strokeWidth = node.strokeWidth
      ..style = PaintingStyle.stroke;
    node.kind == 'ellipse'
        ? canvas.drawOval(rect, p)
        : canvas.drawRect(rect, p);
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.node != node || old.color != color;
}

class ProcessPipePainter extends CustomPainter {
  ProcessPipePainter(this.points, this.color, this.width, this.arrow);
  final List<Offset> points;
  final Color color;
  final double width;
  final bool arrow;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    if (arrow) {
      final end = points.last,
          previous = points[points.length - 2],
          direction = end - previous;
      if (direction.distance == 0) return;
      final unit = direction / direction.distance,
          normal = Offset(-unit.dy, unit.dx),
          length = math.max(10.0, width * 3);
      canvas.drawPath(
        Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(
            (end - unit * length + normal * length * .45).dx,
            (end - unit * length + normal * length * .45).dy,
          )
          ..lineTo(
            (end - unit * length - normal * length * .45).dx,
            (end - unit * length - normal * length * .45).dy,
          )
          ..close(),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(ProcessPipePainter old) => true;
}
