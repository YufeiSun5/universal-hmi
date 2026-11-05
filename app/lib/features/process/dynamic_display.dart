import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

const unknownDisplayColor = Color(0xff64748b);

/// A feedback lamp; blinking affects only the lamp, never the equipment artwork.
class StatusLamp extends StatefulWidget {
  const StatusLamp({super.key, required this.color, this.blink = false});
  final Color color;
  final bool blink;
  @override
  State<StatusLamp> createState() => _StatusLampState();
}

class _StatusLampState extends State<StatusLamp>
    with SingleTickerProviderStateMixin {
  late final AnimationController phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  void sync() {
    phase.stop();
    phase.value = 0;
    if (widget.blink) phase.repeat();
  }

  @override
  void initState() {
    super.initState();
    sync();
  }

  @override
  void didUpdateWidget(StatusLamp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blink != widget.blink || oldWidget.color != widget.color) {
      sync();
    }
  }

  @override
  void dispose() {
    phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: phase,
    builder: (context, child) => Opacity(
      opacity: !widget.blink || phase.value < .5 ? 1 : .18,
      child: child,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        border: Border.all(color: const Color(0xff475569), width: 1),
      ),
    ),
  );
}

class ProcessStateDisplay {
  const ProcessStateDisplay(
    this.text,
    this.color,
    this.known, {
    this.blink = false,
  });
  final String text;
  final Color color;
  final bool known;
  final bool blink;
}

ProcessStateDisplay processStateDisplay(
  ScreenElement node,
  ScreenDocument document,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  final value = processValue(node, document, definitions, live, online);
  if (!value.good) {
    return ProcessStateDisplay(
      '未知 · ${value.text.replaceFirst('— ', '')}',
      unknownDisplayColor,
      false,
    );
  }
  final raw = live[node.pointID]?['value'];
  final number = raw is bool ? (raw ? 1 : 0) : raw;
  final state = node.stateDisplay!;
  final String prefix;
  if (number == state['active_value']) {
    prefix = 'active';
  } else if (number == state['inactive_value']) {
    prefix = 'inactive';
  } else {
    return const ProcessStateDisplay('未知 · 状态值未匹配', unknownDisplayColor, false);
  }
  return ProcessStateDisplay(
    state['${prefix}_text'] as String,
    parseColor(state['${prefix}_color'] as String),
    true,
    blink: state['${prefix}_blink'] == true,
  );
}

class ProcessLevelDisplay {
  const ProcessLevelDisplay(this.ratio, this.text, this.note);
  final double? ratio;
  final String text, note;
  bool get known => ratio != null;
  double get fraction => ratio?.clamp(0.0, 1.0) ?? 0;
}

ProcessLevelDisplay processLevelDisplay(
  ScreenElement node,
  ScreenDocument document,
  Map<String, Json> definitions,
  Map<String, Json> live,
  bool online,
) {
  final value = processValue(node, document, definitions, live, online);
  if (!value.good) {
    return ProcessLevelDisplay(
      null,
      '—',
      '未知 · ${value.text.replaceFirst('— ', '')}',
    );
  }
  final raw = live[node.pointID]?['value'];
  if (raw is! num || !raw.isFinite) {
    return const ProcessLevelDisplay(null, '—', '未知 · 需要数值输入');
  }
  final config = node.levelDisplay!;
  final low = config['minimum'] as num, high = config['maximum'] as num;
  final ratio = (raw - low) / (high - low);
  if (!ratio.isFinite || !(ratio * 100).isFinite) {
    return const ProcessLevelDisplay(null, '—', '未知 · 比例超出数值范围');
  }
  return ProcessLevelDisplay(
    ratio,
    '${(ratio * 100).toStringAsFixed(node.decimals)}%',
    ratio < 0
        ? '低于下限'
        : ratio > 1
        ? '高于上限'
        : '量程 $low ～ $high',
  );
}

class ProcessLevelIndicator extends StatelessWidget {
  const ProcessLevelIndicator({
    super.key,
    required this.node,
    required this.display,
  });
  final ScreenElement node;
  final ProcessLevelDisplay display;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${node.label.isEmpty ? '比例柱' : node.label} ${display.text} ${display.note}',
    child: CustomPaint(
      painter: LevelColumnPainter(
        fraction: display.fraction,
        known: display.known,
        horizontal: node.levelDisplay!['orientation'] == 'horizontal',
        color: node.color,
        background: node.fill ?? const Color(0xffedf2f7),
        overflow: display.known && (display.ratio! < 0 || display.ratio! > 1),
      ),
    ),
  );
}

class LevelColumnPainter extends CustomPainter {
  LevelColumnPainter({
    required this.fraction,
    required this.known,
    required this.horizontal,
    required this.color,
    required this.background,
    this.overflow = false,
  });
  final double fraction;
  final bool known, horizontal, overflow;
  final Color color, background;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1);
    final paint = Paint()..color = background;
    canvas.drawRect(rect, paint);
    canvas.save();
    canvas.clipRect(rect);
    if (known) {
      final fill = horizontal
          ? Rect.fromLTWH(
              rect.left,
              rect.top,
              rect.width * fraction,
              rect.height,
            )
          : Rect.fromLTWH(
              rect.left,
              rect.bottom - rect.height * fraction,
              rect.width,
              rect.height * fraction,
            );
      canvas.drawRect(fill, paint..color = color);
    } else {
      paint
        ..color = unknownDisplayColor.withValues(alpha: .35)
        ..strokeWidth = 1;
      for (double offset = -size.height; offset < size.width; offset += 10) {
        canvas.drawLine(
          Offset(offset, size.height),
          Offset(offset + size.height, 0),
          paint,
        );
      }
    }
    paint
      ..color = const Color(0xff64748b)
      ..strokeWidth = 1;
    canvas.restore();
    canvas.drawRect(
      rect,
      paint
        ..color = overflow ? const Color(0xffd97706) : const Color(0xff64748b)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(LevelColumnPainter old) =>
      old.fraction != fraction ||
      old.overflow != overflow ||
      old.known != known ||
      old.horizontal != horizontal ||
      old.color != color ||
      old.background != background;
}
