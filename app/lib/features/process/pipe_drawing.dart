import 'dart:math' as math;
import 'package:flutter/material.dart';

enum PipeDrawingMode { orthogonal, free, angle }

/// Click history is separate from the committed document's undo history.
class PipeDraft {
  final points = <Offset>[];
  final _undo = <List<Offset>>[], _redo = <List<Offset>>[];
  bool? _horizontalPreview;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get orthogonal =>
      List.generate(math.max(0, points.length - 1), (i) => i).every(
        (i) =>
            points[i].dx == points[i + 1].dx ||
            points[i].dy == points[i + 1].dy,
      );

  List<Offset> preview(
    Offset target,
    PipeDrawingMode mode,
    double step,
    Size bounds, {
    bool connected = false,
  }) {
    if (points.isEmpty) return [target];
    final a = points.last;
    if (mode == PipeDrawingMode.angle && !connected) {
      final delta = target - a;
      final radians = step * math.pi / 180;
      final angle = (delta.direction / radians).round() * radians;
      final direction = Offset(math.cos(angle), math.sin(angle));
      var length = delta.distance;
      if (direction.dx > 1e-10) {
        length = math.min(length, (bounds.width - a.dx) / direction.dx);
      }
      if (direction.dx < -1e-10) {
        length = math.min(length, -a.dx / direction.dx);
      }
      if (direction.dy > 1e-10) {
        length = math.min(length, (bounds.height - a.dy) / direction.dy);
      }
      if (direction.dy < -1e-10) {
        length = math.min(length, -a.dy / direction.dy);
      }
      target = a + direction * length;
    }
    if (mode == PipeDrawingMode.orthogonal && !connected) {
      final delta = target - a;
      // A click confirms ONE straight segment. Small off-axis movement must
      // never create an elbow; hysteresis prevents jitter near the diagonal.
      var horizontal = _horizontalPreview ?? delta.dx.abs() >= delta.dy.abs();
      if (horizontal && delta.dy.abs() > delta.dx.abs() * 1.35) {
        horizontal = false;
      } else if (!horizontal && delta.dx.abs() > delta.dy.abs() * 1.35) {
        horizontal = true;
      }
      _horizontalPreview = horizontal;
      return _simplify([
        ...points,
        horizontal ? Offset(target.dx, a.dy) : Offset(a.dx, target.dy),
      ]);
    }
    // Only an explicit snapped connection may need an automatic elbow.
    final horizontal = points.length < 2
        ? (target.dx - a.dx).abs() >= (target.dy - a.dy).abs()
        : (a.dx - points[points.length - 2].dx).abs() >=
              (a.dy - points[points.length - 2].dy).abs();
    return _simplify([
      ...points,
      if (mode == PipeDrawingMode.orthogonal &&
          (a.dx - target.dx).abs() > 1e-7 &&
          (a.dy - target.dy).abs() > 1e-7)
        horizontal ? Offset(target.dx, a.dy) : Offset(a.dx, target.dy),
      target,
    ]);
  }

  void add(List<Offset> next) {
    if (next.length == points.length &&
        List.generate(
          next.length,
          (i) => i,
        ).every((i) => next[i] == points[i])) {
      return;
    }
    _undo.add(List.of(points));
    if (_undo.length > 256) _undo.removeAt(0);
    _redo.clear();
    _horizontalPreview = null;
    points
      ..clear()
      ..addAll(next);
  }

  void undo() {
    if (!canUndo) return;
    _horizontalPreview = null;
    _redo.add(List.of(points));
    points
      ..clear()
      ..addAll(_undo.removeLast());
  }

  void redo() {
    if (!canRedo) return;
    _horizontalPreview = null;
    _undo.add(List.of(points));
    points
      ..clear()
      ..addAll(_redo.removeLast());
  }

  void clear() {
    points.clear();
    _undo.clear();
    _redo.clear();
    _horizontalPreview = null;
  }

  List<Offset> _simplify(List<Offset> source) {
    final result = <Offset>[];
    for (final p in source) {
      if (result.isNotEmpty && (p - result.last).distance < 1e-7) continue;
      if (result.length >= 2) {
        final a = result.last - result[result.length - 2], b = p - result.last;
        if ((a.dx * b.dy - a.dy * b.dx).abs() < 1e-7 &&
            a.dx * b.dx + a.dy * b.dy >= 0) {
          result.removeLast();
        }
      }
      result.add(p);
    }
    return result;
  }
}
