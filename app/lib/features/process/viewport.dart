import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Uniform scale; small cards must never crop because of a minimum zoom floor.
class ProcessViewport {
  const ProcessViewport(this.scale, this.offset);
  final double scale;
  final Offset offset;
  static ProcessViewport fit(
    Size scene,
    Size container, {
    double padding = 12,
  }) {
    if (scene.isEmpty ||
        container.isEmpty ||
        !scene.width.isFinite ||
        !scene.height.isFinite ||
        !container.width.isFinite ||
        !container.height.isFinite) {
      return const ProcessViewport(1, Offset.zero);
    }
    final inset = math.min(
      padding,
      math.min(container.width, container.height) / 4,
    );
    final scale = math.min(
      (container.width - 2 * inset) / scene.width,
      (container.height - 2 * inset) / scene.height,
    );
    return ProcessViewport(
      scale,
      Offset(
        (container.width - scene.width * scale) / 2,
        (container.height - scene.height * scale) / 2,
      ),
    );
  }
}
