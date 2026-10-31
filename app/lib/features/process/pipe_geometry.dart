import 'dart:math' as math;
import 'package:flutter/material.dart';

class PipeBend {
  const PipeBend(this.start, this.end, this.incoming, this.outgoing);
  final Offset start, end, incoming, outgoing;
}

/// One bounded centerline shared by rendering, hit testing and junctions.
/// Original editing vertices remain untouched.
class PipeRoute {
  const PipeRoute(this.points, this.bends);
  final List<Offset> points;
  final List<PipeBend> bends;
}

PipeRoute pipeRoute(List<Offset> vertices, bool rounded, double radius) {
  if (vertices.length < 2) {
    return PipeRoute(List.of(vertices), const []);
  }
  final points = <Offset>[vertices.first], bends = <PipeBend>[];
  void add(Offset p) {
    final distance = (p - points.last).distance;
    if (distance < 1e-7) return;
    points.add(p);
  }

  for (var i = 1; i < vertices.length - 1; i++) {
    final a = vertices[i - 1], b = vertices[i], c = vertices[i + 1];
    final before = b - a, after = c - b;
    if (before.distance < 1e-7 || after.distance < 1e-7) {
      add(b);
      continue;
    }
    final incoming = before / before.distance,
        outgoing = after / after.distance;
    final cross = incoming.dx * outgoing.dy - incoming.dy * outgoing.dx;
    final angle = math.acos(
      (incoming.dx * outgoing.dx + incoming.dy * outgoing.dy).clamp(-1.0, 1.0),
    );
    if (angle < 1e-7 || cross.abs() < 1e-7) {
      add(b);
      continue;
    }
    final limit = math.min(before.distance, after.distance) / 2;
    if (!rounded) {
      final trim = math.min(radius, limit);
      bends.add(
        PipeBend(b - incoming * trim, b + outgoing * trim, incoming, outgoing),
      );
      add(b);
      continue;
    }
    final trim = math.min(radius * math.tan(angle / 2), limit);
    final actualRadius = trim / math.tan(angle / 2);
    final start = b - incoming * trim, end = b + outgoing * trim;
    final center =
        start + Offset(-incoming.dy, incoming.dx) * actualRadius * cross.sign;
    final startAngle = (start - center).direction;
    // At most 24 arc chords per corner.
    final steps = math.max(2, (angle / (math.pi / 12)).ceil() * 2).clamp(2, 24);
    add(start);
    for (var step = 1; step <= steps; step++) {
      final theta = startAngle + angle * cross.sign * step / steps;
      add(
        step == steps
            ? end
            : center + Offset(math.cos(theta), math.sin(theta)) * actualRadius,
      );
    }
    bends.add(PipeBend(start, end, incoming, outgoing));
  }
  add(vertices.last);
  return PipeRoute(points, bends);
}
