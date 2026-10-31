import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'catalog.dart';
import 'model.dart';
import 'pipe_flow.dart';
import 'symbol_geometry.dart';
import 'symbol_artwork.dart';
import 'presentation.dart';

/// A canvas-sized background; opacity never wraps process elements.
class ProcessBackground extends StatelessWidget {
  const ProcessBackground({super.key, required this.document});
  final ScreenDocument document;
  @override
  Widget build(BuildContext context) {
    final bg = document.background;
    Widget layer;
    if (bg == null) {
      layer = ProcessPresentation.legacyStyle(document)
          ? const DecoratedBox(
              decoration: ProcessPresentation.backdropDecoration,
            )
          : const SizedBox.expand();
    } else {
      final color = parseColor(bg['color'] as String);
      final type = bg['type'];
      if (type == 'linear') {
        final radians = (bg['angle'] as num).toDouble() * math.pi / 180;
        layer = LayoutBuilder(
          builder: (_, size) {
            final x = math.cos(radians), y = math.sin(radians);
            final projection =
                (size.maxWidth * x.abs() + size.maxHeight * y.abs()) / 2;
            final direction = Alignment(
              x * projection / (size.maxWidth / 2),
              y * projection / (size.maxHeight / 2),
            );
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: -direction,
                  end: direction,
                  colors: [color, parseColor(bg['end_color'] as String)],
                ),
              ),
            );
          },
        );
      } else if (type == 'image') {
        final asset = document.assets[bg['image']];
        layer = ColoredBox(
          color: color,
          child: asset == null
              ? const SizedBox.expand()
              : Image.memory(
                  asset.bytes,
                  width: double.infinity,
                  height: double.infinity,
                  fit: switch (bg['fit']) {
                    'contain' => BoxFit.contain,
                    'fill' => BoxFit.fill,
                    _ => BoxFit.cover,
                  },
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Text('背景图片无法读取')),
                ),
        );
      } else {
        layer = ColoredBox(color: color);
      }
      layer = Opacity(opacity: (bg['opacity'] as num).toDouble(), child: layer);
    }
    return ColoredBox(color: Colors.white, child: layer);
  }
}

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
    this.invalidColor = const Color(0xffb7791f),
    this.compactUnboundValues = false,
  });
  final ScreenDocument document;
  final Map<String, ProcessSymbol> symbols;
  final Map<String, Json> definitions, live;
  final bool online;
  final Color invalidColor;
  final bool compactUnboundValues;
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
    final placeholder = compactUnboundValues && value.quality == 'unbound';
    final color = stateColor(n);
    Widget content = switch (n.kind) {
      'symbol' =>
        symbol == null
            ? const Center(child: Text('素材缺失'))
            : LayoutBuilder(
                builder: (_, constraints) => Stack(
                  children: [
                    Positioned.fromRect(
                      rect: symbolContentRect(
                        n.symbol,
                        Offset.zero & constraints.biggest,
                        n.rotation,
                      ),
                      child: RotatedBox(
                        quarterTurns: symbolQuarterTurns(n.rotation),
                        child: ProcessSymbolArtwork(
                          symbol: symbol,
                          fit: BoxFit.fill,
                          colorFilter: symbol.tintable
                              ? ColorFilter.mode(color, BlendMode.srcIn)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
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
            placeholder
                ? '—${n.showUnit && n.unitOverride.isNotEmpty ? ' ${n.unitOverride}' : ''}'
                : value.text,
            key: Key('process-value-${n.id}'),
            maxLines: 1,
            style: TextStyle(
              fontSize: n.fontSize,
              color: value.good || placeholder ? n.color : invalidColor,
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
    if (n.rotation != 0 && n.kind != 'symbol') {
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
        message: n.kind == 'value'
            ? '${n.label.isEmpty ? '变量' : n.label} · ${value.tooltip}'
            : n.pointID.isNotEmpty
            ? value.tooltip
            : n.text.isNotEmpty
            ? n.text
            : symbol?.name ?? n.kind,
        child: content,
      ),
    );
  }

  Widget pipe(ScreenElement n) {
    final state = pipeFlowState(n, document, definitions, live, online);
    final value = processValue(n, document, definitions, live, online);
    final points = document.pipePoints(n);
    final statusPosition = points.firstOrNull ?? Offset(n.x, n.y);
    final status = n.pointID.isNotEmpty && !value.good
        ? value.text
        : state.invalid
        ? '— 箭头条件数据无效'
        : null;
    return Positioned.fill(
      child: IgnorePointer(
        child: PipeFlow(
          key: ValueKey(n.id),
          points: points,
          route: document.pipeRoute(n),
          node: n,
          color: stateColor(n),
          state: state,
          status: status != null
              ? Stack(
                  children: [
                    Positioned(
                      left: statusPosition.dx,
                      top: statusPosition.dy + 5,
                      child: Text(
                        status,
                        key: ValueKey('pipe-status-${n.id}'),
                        style: TextStyle(fontSize: 12, color: invalidColor),
                      ),
                    ),
                  ],
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.hardEdge,
    children: [
      Positioned.fill(child: ProcessBackground(document: document)),
      for (final n in ProcessPresentation.light(document).nodes)
        if (n.id == 'monitor-backdrop' &&
            document.nodes.any(
              (original) =>
                  original.id == n.id &&
                  ProcessPresentation.omitBackdrop(document, original),
            ))
          const SizedBox.shrink()
        else if (n.kind == 'pipe')
          pipe(n)
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

class ProcessPipePainter extends FlowPipePainter {
  ProcessPipePainter(
    super.points,
    super.color,
    super.width,
    super.arrow, {
    super.style,
    super.rounded,
  });
}
