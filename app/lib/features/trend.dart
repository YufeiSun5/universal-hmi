import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';

const curveColors = [
  Color(0xff7195ff),
  Color(0xff36c4b0),
  Color(0xff537995),
  Color(0xff9b779e),
  Color(0xffb95848),
  Color(0xff6f8a45),
];

class Trend extends StatefulWidget {
  const Trend({
    super.key,
    required this.rows,
    required this.names,
    this.rangeFrom,
    this.rangeTo,
  });
  final List<Json> rows;
  final Map<String, String> names;
  final int? rangeFrom, rangeTo;
  @override
  State<Trend> createState() => _TrendState();
}

class _TrendState extends State<Trend> {
  double span = 1, start = 0;
  Offset? pointer;
  bool restored = false;
  final Object _unkeyedViewID = Object();
  // ScrollPosition reserves the implicit PageStorage slot for a double offset.
  // A distinct identifier keeps our two-value viewport out of that slot.
  Object get _viewportStorageID =>
      ('trend-viewport', widget.key ?? _unkeyedViewID);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!restored) {
      final saved = PageStorage.maybeOf(
        context,
      )?.readState(context, identifier: _viewportStorageID);
      if (saved is List<double> && saved.length == 2) {
        span = saved[0];
        start = saved[1];
      }
      restored = true;
    }
  }

  void saveView() => PageStorage.maybeOf(
    context,
  )?.writeState(context, <double>[span, start], identifier: _viewportStorageID);
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final groups = <String, List<Json>>{};
    for (final r in widget.rows) {
      if (DateTime.tryParse(r['source_time'].toString()) == null) {
        continue;
      }
      groups.putIfAbsent(r['point_id'].toString(), () => []).add(r);
    }
    final ids = groups.keys.take(6).toList();
    for (final id in ids) {
      groups[id] = orderedTrendRows(groups[id]!);
    }
    final times = widget.rows
        .map(
          (r) => DateTime.tryParse(
            r['source_time'].toString(),
          )?.millisecondsSinceEpoch,
        )
        .whereType<int>()
        .toList();
    final first =
            widget.rangeFrom ?? (times.isEmpty ? 0 : times.reduce(math.min)),
        last = widget.rangeTo ?? (times.isEmpty ? 1 : times.reduce(math.max)),
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
        .where(validTrendSample)
        .map((r) => (r['value'] as num).toDouble())
        .toList();
    final min = numbers.isEmpty ? 0.0 : numbers.reduce(math.min),
        max = numbers.isEmpty ? 1.0 : numbers.reduce(math.max);
    final padding = math.max(.1, (max - min) * .12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 32,
          child: SingleChildScrollView(
            key: const PageStorageKey<String>('trend-legend-scroll'),
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
                  tooltip: '放大时间范围',
                  onPressed: () => setState(() {
                    final old = span;
                    span = (span * .5).clamp(.01, 1.0);
                    start = (start + (old - span) * .5).clamp(0, 1 - span);
                    saveView();
                  }),
                  icon: const Icon(Icons.zoom_in, size: 17),
                ),
                IconButton(
                  tooltip: '缩小时间范围',
                  onPressed: () => setState(() {
                    final old = span;
                    span = (span * 2).clamp(.01, 1.0);
                    start = (start + (old - span) * .5).clamp(0, 1 - span);
                    saveView();
                  }),
                  icon: const Icon(Icons.zoom_out, size: 17),
                ),
                IconButton(
                  tooltip: '重置范围',
                  onPressed: () => setState(() {
                    span = 1;
                    start = 0;
                    saveView();
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
              final cursorRows = <Json>[];
              if (pointer != null && ids.isNotEmpty) {
                final at =
                    from +
                    ((pointer!.dx - 50) / width).clamp(0, 1) * (to - from);
                for (final id in ids) {
                  Json? nearest;
                  for (final r in view[id] ?? <Json>[]) {
                    if (r['quality'] == 'unit_hidden') continue;
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
                  if (nearest != null) cursorRows.add(nearest);
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
                        saveView();
                      });
                    }
                  },
                  child: GestureDetector(
                    onHorizontalDragEnd: (_) => saveView(),
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
                        if (cursorRows.isNotEmpty)
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
                                  cursorRows
                                      .map(
                                        (r) =>
                                            '${r['name'] != null ? '${r['station']} / ${r['name']}' : widget.names[r['point_id']] ?? r['point_id']}  '
                                            '${validTrendSample(r) ? number(r['value']) : '无效'} ${r['unit'] ?? ''}  '
                                            '[${r['quality']}]  ${clock(r['source_time'])}',
                                      )
                                      .join('\n'),
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
          padding: const EdgeInsets.fromLTRB(50, 4, 18, 6),
          child: LayoutBuilder(
            builder: (context, box) {
              Widget timeLabel(int value, Alignment alignment) => Expanded(
                child: Align(
                  alignment: alignment,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      clock(
                        DateTime.fromMillisecondsSinceEpoch(
                          value,
                        ).toIso8601String(),
                      ),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ),
              );
              return Row(
                children: [
                  timeLabel(from, Alignment.centerLeft),
                  if (box.maxWidth > 620)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '滚轮缩放 · 拖动平移 · 悬停读数',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                  timeLabel(to, Alignment.centerRight),
                ],
              );
            },
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
    final tickCount = rect.height < 70 ? 2 : 4;
    for (int i = 0; i <= tickCount; i++) {
      final y = rect.top + rect.height / tickCount * i;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      final text = TextPainter(
        text: TextSpan(
          text: (max - (max - min) * i / tickCount).toStringAsFixed(1),
          style: TextStyle(
            fontFamily: 'HmiCJK',
            fontSize: 10,
            color: colors.onSurfaceVariant,
          ),
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
      final paint = Paint()
        ..color = curveColors[index++ % curveColors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7;
      for (final segment in trendSegments(rows)) {
        final path = Path();
        Offset? firstPoint;
        for (final r in segment) {
          final at = DateTime.parse(
            r['source_time'].toString(),
          ).millisecondsSinceEpoch;
          final x =
              rect.left + (at - from) / math.max(1, to - from) * rect.width;
          final y =
              rect.bottom -
              ((r['value'] as num).toDouble() - min) /
                  math.max(.001, max - min) *
                  rect.height;
          if (firstPoint == null) {
            firstPoint = Offset(x, y);
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(path, paint);
        if (segment.length == 1 && firstPoint != null) {
          canvas.drawCircle(firstPoint, 2, Paint()..color = paint.color);
        }
      }
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

bool validTrendSample(Json row) =>
    row['value'] is num &&
    (row['value'] as num).isFinite &&
    ['good', 'imported'].contains(row['quality']);

/// Never join through invalid/null values or frozen semantic boundaries.
/// Input is chronological; timestamps remain the actual stored sample times.
List<List<Json>> trendSegments(List<Json> rows) {
  final segments = <List<Json>>[];
  List<Json>? current;
  Json? previous;
  for (final row in rows) {
    if (!validTrendSample(row)) {
      current = null;
      previous = row;
      continue;
    }
    if (row['break_before'] == true ||
        previous != null &&
            (row['unit'] != previous['unit'] ||
                row['version'] != previous['version'] ||
                row['station'] != previous['station'])) {
      current = null;
    }
    if (current == null) {
      current = <Json>[];
      segments.add(current);
    }
    current.add(row);
    previous = row;
  }
  return segments;
}

/// Dart List.sort is unstable: repeated snapshots may share a source time.
/// Frozen sequence orders persisted rows; live rows retain their input order.
List<Json> orderedTrendRows(List<Json> rows) {
  final indexed = [
    for (var i = 0; i < rows.length; i++)
      (
        i,
        rows[i],
        DateTime.parse(
          rows[i]['source_time'].toString(),
        ).microsecondsSinceEpoch,
      ),
  ];
  indexed.sort((a, b) {
    final byTime = a.$3.compareTo(b.$3);
    if (byTime != 0) return byTime;
    final aSeq = a.$2['seq'], bSeq = b.$2['seq'];
    if (aSeq is num && bSeq is num) {
      final bySequence = aSeq.compareTo(bSeq);
      if (bySequence != 0) return bySequence;
    }
    return a.$1.compareTo(b.$1);
  });
  return indexed.map((entry) => entry.$2).toList();
}
