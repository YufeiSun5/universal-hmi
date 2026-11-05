import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'comparison.dart' show comparisonValue, comparisonTime, comparisonNumber;

class ComparisonCharts extends StatefulWidget {
  const ComparisonCharts({super.key, required this.rows, required this.daily});
  final List<Json> rows;
  final bool daily;
  @override
  State<ComparisonCharts> createState() => _ComparisonChartsState();
}

class _ComparisonChartsState extends State<ComparisonCharts> {
  String? selected;
  final tooltip = OverlayPortalController();
  Offset? pointer;
  Json? hovered;
  String? hoveredMetric;
  String hoveredUnit = '';

  void dismiss() {
    tooltip.hide();
    if (mounted) {
      setState(() {
        pointer = null;
        hovered = null;
        selected = null;
      });
    }
  }

  static const current = Color(0xff1976b7), historical = Color(0xffcb7927);
  @override
  Widget build(BuildContext context) {
    final temperatures = <String, Json>{};
    for (final r in widget.rows) {
      temperatures.putIfAbsent('${r['本期开始']}', () => r);
    }
    return OverlayPortal(
      controller: tooltip,
      overlayChildBuilder: (context) {
        if (pointer == null || hovered == null) return const SizedBox.shrink();
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final row = hovered!, temp = hoveredMetric == '气温';
        return Positioned.fill(
          child: IgnorePointer(
            child: CustomSingleChildLayout(
              delegate: _PointerTooltipLayout(overlay.globalToLocal(pointer!)),
              child: Material(
                key: const ValueKey('comparison-pointer-tooltip'),
                elevation: 6,
                borderRadius: BorderRadius.circular(6),
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$hoveredMetric · $hoveredUnit',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '本期 ${comparisonTime(row['本期开始'])}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      Text(
                        comparisonValue(
                          row[temp ? '本期平均气温' : '本期用量'],
                          unit: ' $hoveredUnit',
                        ),
                        style: const TextStyle(color: current),
                      ),
                      Text(
                        '历史 ${comparisonTime(row['历史开始'])}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      Text(
                        comparisonValue(
                          row[temp ? '历史整点气温' : '历史折算用量'],
                          unit: ' $hoveredUnit',
                        ),
                        style: const TextStyle(color: historical),
                      ),
                      if (!temp)
                        Text(
                          '${row['本期状态'] ?? '—'} / ${row['历史状态'] ?? '—'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('● 本期（蓝）    ● 历史（橙）    悬停或触摸曲线联动查看 · 北京时间 UTC+8'),
          ),
          for (final metric in ['气温', '热', '电', '水'])
            Builder(
              builder: (context) {
                final rows = metric == '气温'
                    ? temperatures.values.toList()
                    : widget.rows.where((r) => r['指标'] == metric).toList();
                rows.sort((a, b) => '${a['本期开始']}'.compareTo('${b['本期开始']}'));
                final temp = metric == '气温',
                    a = temp ? '本期平均气温' : '本期用量',
                    b = temp ? '历史整点气温' : '历史折算用量';
                final unit = temp ? '℃' : '${rows.firstOrNull?['单位'] ?? ''}';
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: .3),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '$metric · $unit',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(
                        height: 175,
                        child: LayoutBuilder(
                          builder: (context, box) {
                            void select(Offset point, Offset global) {
                              if (rows.isEmpty) return;
                              final start =
                                  DateTime.tryParse(
                                    '${rows.first['本期开始']}',
                                  )?.millisecondsSinceEpoch ??
                                  0;
                              final end =
                                  DateTime.tryParse(
                                    '${rows.last['本期结束']}',
                                  )?.millisecondsSinceEpoch ??
                                  start + 1;
                              final at =
                                  start +
                                  (end - start) *
                                      ((point.dx - 58) / (box.maxWidth - 74))
                                          .clamp(0, 1);
                              var chosen = rows.first, delta = double.infinity;
                              for (final r in rows) {
                                final stamp = DateTime.tryParse(
                                  '${r['本期开始']}',
                                )?.millisecondsSinceEpoch;
                                if (stamp == null) continue;
                                final d = (stamp - at).abs();
                                if (d < delta) {
                                  delta = d.toDouble();
                                  chosen = r;
                                }
                              }
                              setState(() {
                                selected = '${chosen['本期开始']}';
                                hovered = chosen;
                                hoveredMetric = metric;
                                hoveredUnit = unit;
                                pointer = global;
                              });
                              tooltip.show();
                            }

                            return MouseRegion(
                              key: ValueKey('comparison-plot-$metric'),
                              onHover: (e) =>
                                  select(e.localPosition, e.position),
                              onExit: (_) => dismiss(),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (e) =>
                                    select(e.localPosition, e.globalPosition),
                                onTapUp: (_) => dismiss(),
                                onTapCancel: dismiss,
                                onHorizontalDragUpdate: (e) =>
                                    select(e.localPosition, e.globalPosition),
                                onHorizontalDragEnd: (_) => dismiss(),
                                onHorizontalDragCancel: dismiss,
                                child: CustomPaint(
                                  painter: _ComparisonPainter(
                                    rows,
                                    a,
                                    b,
                                    selected,
                                    widget.daily,
                                    Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _PointerTooltipLayout extends SingleChildLayoutDelegate {
  _PointerTooltipLayout(this.pointer);
  final Offset pointer;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
    maxWidth: math.min(310, math.max(0, c.maxWidth - 16)),
    maxHeight: math.max(0, c.maxHeight - 16),
  );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = pointer.dx + 14, y = pointer.dy + 14;
    if (x + childSize.width > size.width - 8) {
      x = pointer.dx - childSize.width - 14;
    }
    if (y + childSize.height > size.height - 8) {
      y = pointer.dy - childSize.height - 14;
    }
    return Offset(
      x.clamp(8, math.max(8, size.width - childSize.width - 8)),
      y.clamp(8, math.max(8, size.height - childSize.height - 8)),
    );
  }

  @override
  bool shouldRelayout(_PointerTooltipLayout old) => pointer != old.pointer;
}

class _ComparisonPainter extends CustomPainter {
  _ComparisonPainter(
    this.rows,
    this.a,
    this.b,
    this.selected,
    this.daily,
    this.foreground,
  );
  final List<Json> rows;
  final String a, b;
  final String? selected;
  final bool daily;
  final Color foreground;
  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final rect = Rect.fromLTRB(58, 10, size.width - 16, size.height - 28);
    if (rect.width <= 0) return;
    final values = [
      for (final row in rows)
        for (final key in [a, b])
          if (comparisonNumber(row[key]) != null) comparisonNumber(row[key])!,
    ];
    var lo = values.isEmpty ? 0.0 : values.reduce(math.min),
        hi = values.isEmpty ? 1.0 : values.reduce(math.max);
    if (a == '本期用量') lo = math.min(0, lo);
    if (lo == hi) {
      lo -= 1;
      hi += 1;
    } else {
      final pad = (hi - lo) * .08;
      lo -= pad;
      hi += pad;
    }
    final start = DateTime.parse(
      '${rows.first['本期开始']}',
    ).millisecondsSinceEpoch;
    final finish = DateTime.parse(
      '${rows.last['本期结束']}',
    ).millisecondsSinceEpoch;
    double x(Json row) =>
        rect.left +
        (DateTime.parse('${row['本期开始']}').millisecondsSinceEpoch - start) /
            math.max(1, finish - start) *
            rect.width;
    double y(double n) => rect.bottom - (n - lo) / (hi - lo) * rect.height;
    void text(String value, Offset at, {bool right = false}) {
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontSize: 10,
            color: foreground,
            fontFamily: 'HmiCJK',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, Offset(right ? at.dx - p.width : at.dx, at.dy));
    }

    final grid = Paint()
      ..color = foreground.withValues(alpha: .12)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final yy = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, yy), Offset(rect.right, yy), grid);
      text(
        (hi - (hi - lo) * i / 4).toStringAsFixed(1),
        Offset(rect.left - 7, yy - 6),
        right: true,
      );
    }
    final timeIntervals = (rect.width / (daily ? 90 : 180)).floor().clamp(1, 3);
    for (var i = 0; i <= timeIntervals; i++) {
      final t = DateTime.fromMillisecondsSinceEpoch(
        (start + (finish - start) * i / timeIntervals).round(),
        isUtc: true,
      ).add(const Duration(hours: 8));
      final label = daily
          ? '${t.month}/${t.day}'
          : '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      text(
        label,
        Offset(rect.left + rect.width * i / timeIntervals, rect.bottom + 8),
        right: i > 0,
      );
    }
    canvas.save();
    canvas.clipRect(rect.inflate(3));
    for (final pair in [
      (a, _ComparisonChartsState.current),
      (b, _ComparisonChartsState.historical),
    ]) {
      Offset? previous;
      String? previousEnd;
      final line = Paint()
        ..color = pair.$2
        ..strokeWidth = 1.8;
      for (final r in rows) {
        final n = comparisonNumber(r[pair.$1]);
        if (n == null) {
          previous = null;
          previousEnd = null;
          continue;
        }
        final point = Offset(x(r), y(n));
        if (previous != null && previousEnd == '${r['本期开始']}') {
          canvas.drawLine(previous, point, line);
        }
        // Always expose isolated valid points instead of erasing them between gaps.
        if (rows.length < 200 || previous == null || r['本期开始'] == selected) {
          canvas.drawCircle(point, 2.5, line);
        }
        previous = point;
        previousEnd = '${r['本期结束']}';
      }
    }
    final chosen = rows.where((r) => r['本期开始'] == selected).firstOrNull;
    if (chosen != null) {
      final xx = x(chosen);
      canvas.drawLine(
        Offset(xx, rect.top),
        Offset(xx, rect.bottom),
        Paint()
          ..color = foreground.withValues(alpha: .4)
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
    if (values.isEmpty) {
      text('当前窗口无有效数据', Offset(rect.left + 12, rect.center.dy));
    }
  }

  @override
  bool shouldRepaint(covariant _ComparisonPainter old) => true;
}
