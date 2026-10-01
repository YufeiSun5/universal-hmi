import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';

const curveColors = [
  Color(0xff7ba0ff),
  Color(0xff53cdb0),
  Color(0xffe8b86a),
  Color(0xffc791ed),
  Color(0xffeb839d),
  Color(0xff75c6e8),
];

class Trend extends StatefulWidget {
  const Trend({super.key, required this.rows, required this.names});
  final List<Json> rows;
  final Map<String, String> names;
  @override
  State<Trend> createState() => _TrendState();
}

class _TrendState extends State<Trend> {
  double span = 1, start = 0;
  Offset? pointer;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final groups = <String, List<Json>>{};
    for (final r in widget.rows) {
      if (r['value'] is! num ||
          DateTime.tryParse(r['source_time'].toString()) == null) {
        continue;
      }
      groups.putIfAbsent(r['point_id'].toString(), () => []).add(r);
    }
    final ids = groups.keys.take(6).toList();
    for (final id in ids) {
      groups[id]!.sort(
        (a, b) =>
            a['source_time'].toString().compareTo(b['source_time'].toString()),
      );
    }
    final times = widget.rows
        .map(
          (r) => DateTime.tryParse(
            r['source_time'].toString(),
          )?.millisecondsSinceEpoch,
        )
        .whereType<int>()
        .toList();
    final first = times.isEmpty ? 0 : times.reduce(math.min),
        last = times.isEmpty ? 1 : times.reduce(math.max),
        range = math.max(1, last - first);
    final from = first + (range * start).toInt(),
        to = from + (range * span).toInt();
    final view = <String, List<Json>>{};
    for (final id in ids) {
      view[id] = groups[id]!.where((r) {
        final t = DateTime.parse(
          r['source_time'].toString(),
        ).millisecondsSinceEpoch;
        return t >= from && t <= to;
      }).toList();
    }
    final numbers = view.values
        .expand((v) => v)
        .where((r) => r['quality'] == 'good' || r['quality'] == 'imported')
        .map((r) => (r['value'] as num).toDouble())
        .toList();
    final min = numbers.isEmpty ? 0.0 : numbers.reduce(math.min),
        max = numbers.isEmpty ? 1.0 : numbers.reduce(math.max);
    final padding = math.max(.1, (max - min) * .12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 38,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: 10),
                ...List.generate(
                  ids.length,
                  (i) => Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: curveColors[i],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.names[ids[i]] ?? ids[i],
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '重置范围',
                  onPressed: () => setState(() {
                    span = 1;
                    start = 0;
                  }),
                  icon: const Icon(Icons.fit_screen, size: 17),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final width = math.max(1.0, box.maxWidth - 68);
              Json? nearest;
              if (pointer != null && ids.isNotEmpty) {
                final at =
                    from +
                    ((pointer!.dx - 50) / width).clamp(0, 1) * (to - from);
                for (final r in view[ids.first] ?? <Json>[]) {
                  if (nearest == null ||
                      (DateTime.parse(
                                    r['source_time'].toString(),
                                  ).millisecondsSinceEpoch -
                                  at)
                              .abs() <
                          (DateTime.parse(
                                    nearest['source_time'].toString(),
                                  ).millisecondsSinceEpoch -
                                  at)
                              .abs()) {
                    nearest = r;
                  }
                }
              }
              return MouseRegion(
                onHover: (e) => setState(() => pointer = e.localPosition),
                onExit: (_) => setState(() => pointer = null),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      setState(() {
                        final old = span;
                        span = (span * (event.scrollDelta.dy > 0 ? 1.2 : .8))
                            .clamp(.01, 1.0);
                        start = (start + (old - span) * .5).clamp(0, 1 - span);
                      });
                    }
                  },
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(
                      () => start = (start - d.delta.dx / width * span).clamp(
                        0,
                        1 - span,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: TrendPainter(
                              view,
                              from,
                              to,
                              min - padding,
                              max + padding,
                              c,
                              pointer,
                            ),
                          ),
                        ),
                        if (numbers.isEmpty)
                          const Center(child: Text('所选范围暂无有效数值')),
                        if (nearest != null)
                          Positioned(
                            top: 8,
                            right: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: c.surfaceContainerHigh,
                                border: Border.all(color: c.outlineVariant),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '${clock(nearest['source_time'])}\n${number(nearest['value'])} ${nearest['unit'] ?? ''}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(50, 4, 12, 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  clock(
                    DateTime.fromMillisecondsSinceEpoch(from).toIso8601String(),
                  ),
                  style: const TextStyle(fontSize: 10),
                ),
                const SizedBox(width: 16),
                const Text(
                  '滚轮缩放 · 拖动平移 · 悬停读数',
                  style: TextStyle(fontSize: 10),
                ),
                const SizedBox(width: 16),
                Text(
                  clock(
                    DateTime.fromMillisecondsSinceEpoch(to).toIso8601String(),
                  ),
                  style: const TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TrendPainter extends CustomPainter {
  TrendPainter(
    this.groups,
    this.from,
    this.to,
    this.min,
    this.max,
    this.colors,
    this.pointer,
  );
  final Map<String, List<Json>> groups;
  final int from, to;
  final double min, max;
  final ColorScheme colors;
  final Offset? pointer;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(50, 10, size.width - 18, size.height - 12);
    if (rect.width <= 0 || rect.height <= 0) return;
    final grid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: .4)
      ..strokeWidth = .5;
    for (int i = 0; i <= 4; i++) {
      final y = rect.top + rect.height / 4 * i;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      final text = TextPainter(
        text: TextSpan(
          text: (max - (max - min) * i / 4).toStringAsFixed(1),
          style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(3, y - 6));
    }
    for (int i = 0; i <= 8; i++) {
      final x = rect.left + rect.width / 8 * i;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
    }
    canvas.save();
    canvas.clipRect(rect);
    int index = 0;
    for (final rows in groups.values) {
      final path = Path();
      bool open = false;
      for (final r in rows) {
        if (r['quality'] != 'good' && r['quality'] != 'imported') {
          open = false;
          continue;
        }
        final at = DateTime.parse(
          r['source_time'].toString(),
        ).millisecondsSinceEpoch;
        final x = rect.left + (at - from) / math.max(1, to - from) * rect.width,
            y =
                rect.bottom -
                ((r['value'] as num).toDouble() - min) /
                    math.max(.001, max - min) *
                    rect.height;
        if (open) {
          path.lineTo(x, y);
        } else {
          path.moveTo(x, y);
          open = true;
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = curveColors[index++ % curveColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7,
      );
    }
    if (pointer != null && rect.contains(pointer!)) {
      canvas.drawLine(
        Offset(pointer!.dx, rect.top),
        Offset(pointer!.dx, rect.bottom),
        Paint()
          ..color = colors.onSurfaceVariant
          ..strokeWidth = .6,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TrendPainter oldDelegate) => true;
}
