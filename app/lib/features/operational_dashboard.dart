import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/theme.dart';

class OperationalPanel extends StatelessWidget {
  const OperationalPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.titleKey,
  });
  final String title;
  final Key? titleKey;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        height: 27,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(
          color: WorkbenchColors.chrome,
          border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
        ),
        child: Row(
          children: [
            Text(
              title,
              key: titleKey,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
      Expanded(child: child),
    ],
  );
}

class SampleSparkline extends StatelessWidget {
  const SampleSparkline({
    super.key,
    required this.rows,
    this.color = WorkbenchColors.accent,
  });
  final List<Json> rows;
  final Color color;
  @override
  Widget build(BuildContext context) => rows.length < 2
      ? const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '等待趋势样本',
            style: TextStyle(fontSize: 9, color: WorkbenchColors.muted),
          ),
        )
      : CustomPaint(
          painter: _SparklinePainter(rows, color),
          size: Size.infinite,
        );
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.rows, this.color);
  final List<Json> rows;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final valid = rows
        .where((r) => r['value'] is num && r['quality'] == 'good')
        .toList();
    if (valid.length < 2) return;
    final numbers = valid.map((r) => (r['value'] as num).toDouble());
    final low = numbers.reduce(math.min), high = numbers.reduce(math.max);
    final start = DateTime.tryParse(
      rows.first['source_time'].toString(),
    )?.millisecondsSinceEpoch;
    final end = DateTime.tryParse(
      rows.last['source_time'].toString(),
    )?.millisecondsSinceEpoch;
    if (start == null || end == null) return;
    final rect = Rect.fromLTWH(0, 2, size.width, math.max(1, size.height - 4));
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final path = Path();
    bool open = false;
    for (final row in rows) {
      final time = DateTime.tryParse(
        row['source_time'].toString(),
      )?.millisecondsSinceEpoch;
      if (row['quality'] != 'good' || row['value'] is! num || time == null) {
        open = false;
        continue;
      }
      final x = (time - start) / math.max(1, end - start) * rect.width;
      final y = high == low
          ? rect.center.dy
          : rect.bottom -
                ((row['value'] as num).toDouble() - low) /
                    (high - low) *
                    rect.height;
      if (open) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        open = true;
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) => true;
}

class EngineeringRange extends StatelessWidget {
  const EngineeringRange({
    super.key,
    required this.value,
    required this.minimum,
    required this.maximum,
  });
  final dynamic value, minimum, maximum;
  @override
  Widget build(BuildContext context) {
    if (value is! num ||
        minimum is! num ||
        maximum is! num ||
        maximum <= minimum) {
      return const Text(
        '工程范围未配置',
        style: TextStyle(fontSize: 9, color: WorkbenchColors.muted),
      );
    }
    final ratio = ((value - minimum) / (maximum - minimum))
        .clamp(0.0, 1.0)
        .toDouble();
    final outside = value < minimum || value > maximum;
    return Row(
      children: [
        Text(
          number(minimum),
          style: const TextStyle(fontSize: 9, color: WorkbenchColors.muted),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: WorkbenchColors.line,
            color: outside ? WorkbenchColors.amber : const Color(0xff8298c4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          number(maximum),
          style: const TextStyle(fontSize: 9, color: WorkbenchColors.muted),
        ),
      ],
    );
  }
}
