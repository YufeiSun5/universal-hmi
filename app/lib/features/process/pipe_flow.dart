import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';
import 'pipe_geometry.dart';

/// Display conditions only. Never executes runtime rules or device commands.
class PipeFlowState {
  const PipeFlowState(this.visible, this.moving, this.invalid);
  final bool visible, moving, invalid;
}

bool? evaluateArrowRule(
  Json? rule,
  String station,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  if (rule == null) return true;
  final conditions = objects(rule['conditions']);
  if (!online || conditions.isEmpty) return null;
  final results = <bool>[];
  for (final c in conditions) {
    final id = c['point_id'] as String? ?? '',
        definition = definitions[id],
        sample = live[id];
    final raw = sample?['value'], threshold = c['value'];
    if (id.isEmpty ||
        definition == null ||
        sample?['quality'] != 'good' ||
        threshold is! num ||
        !threshold.isFinite ||
        raw is! num && raw is! bool ||
        raw is num && !raw.isFinite) {
      return null;
    }
    final value = raw is bool ? (raw ? 1 : 0) : raw as num;
    results.add(switch (c['operator']) {
      '>' => value > threshold,
      '<' => value < threshold,
      '>=' => value >= threshold,
      '<=' => value <= threshold,
      '==' => value == threshold,
      '!=' => value != threshold,
      _ => false,
    });
  }
  return rule['match'] == 'any'
      ? results.any((v) => v)
      : results.every((v) => v);
}

PipeFlowState pipeFlowState(
  ScreenElement node,
  ScreenDocument document,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  final visible = evaluateArrowRule(
    node.arrowVisibleRule,
    document.station,
    definitions,
    live,
    online,
  );
  final moving = evaluateArrowRule(
    node.arrowMotionRule,
    document.station,
    definitions,
    live,
    online,
  );
  final bindingValid =
      node.pointID.isEmpty ||
      processValue(node, document, definitions, live, online).good;
  return PipeFlowState(
    node.arrow && bindingValid && visible == true,
    node.arrow &&
        bindingValid &&
        visible == true &&
        node.arrowAnimate &&
        moving == true,
    node.arrow &&
        (!bindingValid ||
            visible == null ||
            node.arrowAnimate && moving == null),
  );
}

List<double> arrowDistances(
  List<Offset> points,
  String mode,
  double spacing,
  int count,
  double phase,
) {
  final lengths = List.generate(
    math.max(0, points.length - 1),
    (i) => (points[i + 1] - points[i]).distance,
  );
  final total = lengths.fold(0.0, (a, b) => a + b);
  if (total <= 0) return [];
  final result = <double>[];
  if (mode == 'single') {
    return [phase == 0 ? total : (total * .5 + phase) % total];
  }
  final byCount = mode == 'count' || mode == 'segments';
  final step = byCount ? total / count : spacing;
  if (byCount) {
    return [
      for (var i = 0; i < count && i < 512; i++)
        ((i + .5) * step + phase) % total,
    ];
  }
  for (
    var d = step / 2 + phase % step;
    d < total && result.length < 512;
    d += step
  ) {
    result.add(d);
  }
  return result;
}

class PipeFlow extends StatefulWidget {
  const PipeFlow({
    super.key,
    required this.points,
    required this.node,
    required this.color,
    required this.state,
    this.status,
    this.route,
  });
  final List<Offset> points;
  final ScreenElement node;
  final Color color;
  final PipeFlowState state;
  final Widget? status;
  final PipeRoute? route;
  @override
  State<PipeFlow> createState() => _PipeFlowState();
}

class _PipeFlowState extends State<PipeFlow>
    with SingleTickerProviderStateMixin {
  late final clock = AnimationController(
    vsync: this,
    duration: const Duration(hours: 1),
    animationBehavior: AnimationBehavior.preserve,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(PipeFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    // Flow is the configured process indication, not a decorative transition.
    // Keep its speed observable when the OS reduces UI animations; runtime
    // conditions and input quality still decide whether it may move.
    final moving = widget.state.moving;
    if (moving && !clock.isAnimating) clock.repeat();
    if (!moving && clock.isAnimating) clock.stop();
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    child: widget.status,
    builder: (_, child) => CustomPaint(
      painter: FlowPipePainter(
        widget.points,
        widget.color,
        widget.node.strokeWidth,
        widget.state.visible,
        style: widget.node.pipeStyle,
        rounded: widget.node.pipeRounded,
        bendRadius: widget.node.pipeBendRadius,
        elbows: widget.node.pipeElbows,
        route: widget.route,
        mode: widget.node.arrowMode,
        spacing: widget.node.arrowSpacing,
        count: widget.node.arrowCount,
        reverse: widget.node.arrowReverse,
        phase: widget.state.moving && clock.isAnimating
            ? clock.value * 3600 * widget.node.arrowSpeed
            : 0,
      ),
      child: child,
    ),
  );
}

class FlowPipePainter extends CustomPainter {
  FlowPipePainter(
    this.points,
    this.color,
    this.width,
    this.arrow, {
    this.mode = 'single',
    this.spacing = 80,
    this.count = 3,
    this.phase = 0,
    this.style = 'flat',
    this.rounded = false,
    this.elbows = false,
    this.reverse = false,
    double bendRadius = 24,
    PipeRoute? route,
  }) : route = route ?? pipeRoute(points, rounded, bendRadius);
  final List<Offset> points;
  final Color color;
  final double width, spacing, phase;
  final bool arrow;
  final bool rounded, elbows, reverse;
  final PipeRoute route;
  final String mode, style;
  final int count;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final line = route.points;
    if (line.length < 2) return;
    final path = Path()..moveTo(line.first.dx, line.first.dy);
    for (final p in line.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (style == 'cylinder') {
      _paintCylinder(canvas, path, line);
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
    if (elbows) _paintElbows(canvas);
    if (!arrow) return;
    final metric = path.computeMetrics().firstOrNull;
    if (metric == null) return;
    for (final distance in arrowDistances(
      line,
      mode,
      spacing,
      count,
      reverse ? -phase : phase,
    )) {
      final tangent = metric.getTangentForOffset(
        reverse && mode == 'single' && phase == 0 ? 0 : distance,
      );
      if (tangent == null) continue;
      final end = tangent.position,
          unit = reverse ? -tangent.vector : tangent.vector,
          normal = Offset(-unit.dy, unit.dx),
          length = style == 'cylinder'
              ? math.max(6.0, width * .9)
              : math.max(10.0, width * 3),
          wing = style == 'cylinder' ? .35 : .45;
      final left = end - unit * length + normal * length * wing,
          right = end - unit * length - normal * length * wing;
      final shape = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..close();
      if (style == 'cylinder') {
        canvas.drawPath(
          shape,
          Paint()
            ..color = Color.lerp(color, Colors.black, .6)!
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = math.max(.5, width * .08),
        );
      }
      canvas.drawPath(
        shape,
        Paint()..color = style == 'cylinder' ? Colors.white : color,
      );
    }
  }

  void _paintCylinder(Canvas canvas, Path path, List<Offset> line) {
    final dark = Color.lerp(color, Colors.black, .6)!;
    final bright = Color.lerp(color, Colors.white, .78)!;
    Paint stroke(Color ink, double thickness) => Paint()
      ..color = ink
      ..strokeWidth = thickness
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // Native vector shading keeps the same geometry, selection and anchors.
    canvas.drawPath(
      path.shift(Offset(width * .12, width * .12)),
      stroke(Colors.black.withValues(alpha: .16), width),
    );
    canvas.drawPath(path, stroke(dark, width));
    for (var i = 1; i < line.length; i++) {
      final a = line[i - 1], b = line[i], delta = b - a;
      if (delta.distance < 1e-7) continue;
      var normal = Offset(-delta.dy, delta.dx) / delta.distance;
      // A fixed upper-left light source works for horizontal, vertical and
      // arbitrary angle pipes regardless of drawing direction.
      final lightSide = normal.dx + normal.dy;
      if (lightSide < -1e-10 || lightSide.abs() < 1e-10 && normal.dy < 0) {
        normal = -normal;
      }
      final paint = stroke(color, width * .92)
        // The gradient runs across the pipe, not along its length.
        ..shader = _crossSectionShader(a, normal, dark, bright);
      canvas.drawLine(a, b, paint);
    }
    // Round elbows blend the transverse gradients at each bend.
    for (final p
        in rounded
            ? const <Offset>[]
            : points.skip(1).take(points.length - 2)) {
      canvas.drawCircle(
        p,
        width * .46,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.35, -.45),
            radius: .95,
            colors: [bright, color, dark],
            stops: const [0, .48, 1],
          ).createShader(Rect.fromCircle(center: p, radius: width * .46)),
      );
    }
  }

  void _paintElbows(Canvas canvas) {
    final metal = Color.lerp(color, Colors.white, .55)!;
    final dark = Color.lerp(color, Colors.black, .65)!;
    for (final bend in route.bends) {
      for (final sleeve in [
        (bend.start, bend.incoming),
        (bend.end, bend.outgoing),
      ]) {
        canvas.save();
        canvas.translate(sleeve.$1.dx, sleeve.$1.dy);
        canvas.rotate(sleeve.$2.direction);
        final bounds = Rect.fromCenter(
          center: Offset.zero,
          width: math.max(3, width * .32),
          height: width * 1.22,
        );
        final shape = RRect.fromRectAndRadius(bounds, const Radius.circular(1));
        canvas.drawRRect(
          shape,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [dark, metal, Colors.white, metal, dark],
              stops: const [0, .2, .34, .65, 1],
            ).createShader(bounds),
        );
        canvas.drawRRect(
          shape,
          Paint()
            ..color = dark
            ..style = PaintingStyle.stroke
            ..strokeWidth = .7,
        );
        canvas.restore();
      }
    }
  }

  ui.Shader _crossSectionShader(
    Offset a,
    Offset normal,
    Color dark,
    Color bright,
  ) => ui.Gradient.linear(
    a - normal * width * .46,
    a + normal * width * .46,
    [dark, color, bright, color, dark],
    const [0, .14, .32, .62, 1],
  );

  @override
  bool shouldRepaint(FlowPipePainter old) =>
      points != old.points ||
      color != old.color ||
      width != old.width ||
      arrow != old.arrow ||
      mode != old.mode ||
      spacing != old.spacing ||
      count != old.count ||
      phase != old.phase ||
      style != old.style ||
      rounded != old.rounded ||
      elbows != old.elbows ||
      reverse != old.reverse ||
      route != old.route;
}
