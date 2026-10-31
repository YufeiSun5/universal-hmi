import 'package:flutter/material.dart';
import 'model.dart';

class AlignmentGuide {
  const AlignmentGuide(this.vertical, this.position);
  final bool vertical;
  final double position;
}

class AlignmentSnap {
  const AlignmentSnap(this.delta, this.guides);
  final Offset delta;
  final List<AlignmentGuide> guides;
}

/// Screen-space tolerance supplied by the canvas. Guides never enter JSON.
AlignmentSnap alignToScene(
  ScreenDocument document,
  List<Offset> anchors,
  double tolerance, {
  String exclude = '',
  bool allowX = true,
  bool allowY = true,
}) {
  final xs = <double>[], ys = <double>[];
  for (final node in document.nodes) {
    if (node.id == exclude) continue;
    if (node.kind != 'pipe') {
      xs.add(node.rect.center.dx);
      ys.add(node.rect.center.dy);
    } else {
      final points = document.pipePoints(node);
      if (points.isEmpty) continue;
      xs.addAll([points.first.dx, points.last.dx]);
      ys.addAll([points.first.dy, points.last.dy]);
      for (var i = 1; i < points.length; i++) {
        if ((points[i].dx - points[i - 1].dx).abs() < 1e-7) {
          xs.add(points[i].dx);
        }
        if ((points[i].dy - points[i - 1].dy).abs() < 1e-7) {
          ys.add(points[i].dy);
        }
      }
    }
  }
  (double, double)? nearest(List<double> targets, bool vertical) {
    (double, double)? best;
    var distance = tolerance;
    for (final anchor in anchors) {
      final coordinate = vertical ? anchor.dx : anchor.dy;
      for (final target in targets) {
        final delta = target - coordinate;
        if (delta.abs() <= distance) {
          distance = delta.abs();
          best = (delta, target);
        }
      }
    }
    return best;
  }

  final x = allowX ? nearest(xs, true) : null;
  final y = allowY ? nearest(ys, false) : null;
  return AlignmentSnap(Offset(x?.$1 ?? 0, y?.$1 ?? 0), [
    if (x != null) AlignmentGuide(true, x.$2),
    if (y != null) AlignmentGuide(false, y.$2),
  ]);
}

class AlignmentGuidePainter extends CustomPainter {
  const AlignmentGuidePainter(this.guides, this.zoom);
  final List<AlignmentGuide> guides;
  final double zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xffa855f7)
      ..strokeWidth = 1 / zoom;
    for (final guide in guides) {
      final p = guide.position;
      canvas.drawLine(
        guide.vertical ? Offset(p, 0) : Offset(0, p),
        guide.vertical ? Offset(p, size.height) : Offset(size.width, p),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(AlignmentGuidePainter old) =>
      guides != old.guides || zoom != old.zoom;
}
