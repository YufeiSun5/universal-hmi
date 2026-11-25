import 'dart:math' as math;
import 'package:flutter/material.dart';

const ice = Color(0xff57e9ff);
const mint = Color(0xff48ebcc);
const violet = Color(0xffb4a2ff);
const dim = Color(0xff9ebcdb);

List<double?> valuesOf(Object? value) =>
    value is List ? [for (final item in value) numberOf(item)] : const [];

double? numberOf(Object? value) {
  final result = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return result != null && result.isFinite ? result : null;
}

String reading(Object? value, [int digits = 0]) {
  final number = numberOf(value);
  if (number == null) return '—';
  final parts = number.toStringAsFixed(digits).split('.');
  final whole = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return parts.length == 1 ? whole : '$whole.${parts.last}';
}

class CockpitPlot extends StatelessWidget {
  const CockpitPlot({
    super.key,
    required this.values,
    this.labels = const [],
    this.color = ice,
    this.grid = true,
    this.showScale = false,
    this.area = false,
    this.startAtZero = false,
  });

  final List<double?> values;
  final List<String> labels;
  final Color color;
  final bool grid, showScale, area, startAtZero;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _Plot(this, Theme.of(context).textTheme.bodySmall?.fontFamily),
  );
}

class _Plot extends CustomPainter {
  _Plot(this.style, this.font);
  final CockpitPlot style;
  final String? font;

  void text(Canvas c, String value, Offset at, {bool center = false}) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: dim, fontSize: 12, fontFamily: font),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, at.translate(center ? -p.width / 2 : 0, 0));
    p.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      style.area
          ? 30
          : (style.showScale ? 43 : (style.labels.isEmpty ? 3 : 17)),
      8,
      size.width - (style.labels.isEmpty ? 3 : 17),
      size.height - (style.labels.isEmpty ? 4 : 23),
    );
    if (rect.isEmpty) return;
    final valid = style.values.whereType<double>();
    var low = valid.isEmpty ? 0.0 : valid.reduce(math.min);
    var high = valid.isEmpty ? 1.0 : valid.reduce(math.max);
    if (style.startAtZero) low = math.min(0, low);
    if (low == high) {
      high += 1;
      if (!style.startAtZero) low -= 1;
    }
    if (style.area) {
      low = low.floorToDouble();
      high = high.ceilToDouble();
    }
    if (style.showScale && style.startAtZero && low == 0) {
      final interval = high / 4;
      final magnitude = math.pow(10, (math.log(interval) / math.ln10).floor());
      final step = [
        1,
        1.25,
        1.5,
        2,
        2.5,
        3,
        4,
        5,
        6,
        8,
        10,
      ].firstWhere((n) => n * magnitude >= interval);
      high = (step * magnitude * 4).toDouble();
    }
    final border = Paint()
      ..color = style.area ? const Color(0xff203b55) : const Color(0xff254569)
      ..strokeWidth = 1;
    if (style.grid) {
      final divisions = style.area
          ? 2
          : (!style.showScale || rect.height >= 68
                ? 4
                : math.max(1, (rect.height / 19).floor()));
      for (var i = 0; i <= divisions; i++) {
        final y = rect.bottom - i * rect.height / divisions;
        canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), border);
        if (style.showScale) {
          final value = low + (high - low) * i / divisions;
          text(
            canvas,
            reading(value, style.area && value != value.truncate() ? 1 : 0),
            Offset(2, y - 8),
          );
        }
      }
    }
    for (var i = 0; i < style.labels.length; i++) {
      if (style.labels[i].isEmpty) continue;
      final x =
          rect.left + i * rect.width / math.max(1, style.labels.length - 1);
      if (style.grid && !style.area) {
        canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), border);
      }
      text(canvas, style.labels[i], Offset(x, rect.bottom + 5), center: true);
    }
    if (valid.isEmpty) return;
    final step = rect.width / math.max(1, style.values.length - 1);
    Offset point(int i, double v) => Offset(
      rect.left + i * step,
      rect.bottom - (v - low) * rect.height / (high - low),
    );
    if (style.area) {
      final fill = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            style.color.withValues(alpha: .32),
            style.color.withValues(alpha: .025),
          ],
        ).createShader(rect);
      final pen = Paint()
        ..color = style.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (var i = 0; i < style.values.length;) {
        final value = style.values[i];
        if (value == null) {
          i++;
          continue;
        }
        final first = point(i++, value);
        var last = first;
        final path = Path()..moveTo(first.dx, first.dy);
        while (i < style.values.length && style.values[i] != null) {
          last = point(i, style.values[i]!);
          path.lineTo(last.dx, last.dy);
          i++;
        }
        if (last == first) {
          canvas.drawCircle(first, 2.4, Paint()..color = style.color);
          continue;
        }
        final area = Path.from(path)
          ..lineTo(last.dx, rect.bottom)
          ..lineTo(first.dx, rect.bottom)
          ..close();
        canvas.drawPath(area, fill);
        canvas.drawPath(path, pen);
      }
      return;
    }

    Offset? previous;
    final pen = Paint()
      ..color = style.color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < style.values.length; i++) {
      final value = style.values[i];
      if (value == null) {
        previous = null;
        continue;
      }
      final p = point(i, value);
      if (previous != null) canvas.drawLine(previous, p, pen);
      if (style.labels.isNotEmpty) canvas.drawCircle(p, 2, pen);
      previous = p;
    }
  }

  @override
  bool shouldRepaint(covariant _Plot oldDelegate) =>
      oldDelegate.style.values != style.values ||
      oldDelegate.style.labels != style.labels;
}

class CockpitPanel extends StatelessWidget {
  const CockpitPanel(
    this.title,
    this.child, {
    super.key,
    this.detail,
    this.pinnedHeader,
    this.pinnedFooter,
  });
  final String title;
  final Widget child;
  final Widget? detail;
  final Widget? pinnedHeader, pinnedFooter;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xff0b2344), Color(0xff071a35), Color(0xff081730)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: const Color(0xff2b5273)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            gradient: LinearGradient(
              colors: [Color(0xff184061), Color(0xff102b46), Color(0xff0d223b)],
            ),
            border: Border(bottom: BorderSide(color: Color(0xff2b526e))),
          ),
          child: Row(
            children: [
              Container(width: 3, height: 17, color: ice),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .6,
                  ),
                ),
              ),
              ?detail,
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
            child: pinnedHeader == null && pinnedFooter == null
                ? child
                : Column(
                    children: [
                      ?pinnedHeader,
                      Expanded(child: child),
                      ?pinnedFooter,
                    ],
                  ),
          ),
        ),
      ],
    ),
  );
}

class CockpitTitle extends StatelessWidget {
  const CockpitTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _TitleWings(),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: SizedBox(
          width: 740,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xfff0faff),
                fontSize: 52,
                fontWeight: FontWeight.w900,
                letterSpacing: 5,
                shadows: [
                  Shadow(offset: Offset(0, 3), color: Color(0xff36678e)),
                  Shadow(blurRadius: 24, color: Color(0xff1978cb)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TitleWings extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height;
    final cx = size.width / 2;
    final glow = Paint()
      ..shader =
          const RadialGradient(
            colors: [Color(0x8c125e9a), Color(0x00135086)],
          ).createShader(
            Rect.fromCenter(center: Offset(cx, y), width: 1220, height: 160),
          );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, y), width: 1220, height: 142),
      glow,
    );
    void wing() {
      final path = Path()
        ..moveTo(6, y * .44)
        ..lineTo(cx - 495, y * .20)
        ..lineTo(cx - 419, y * .20)
        ..lineTo(cx - 366, y * .72)
        ..lineTo(cx - 410, y * .72)
        ..lineTo(cx - 460, y * .37)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0x002877d1), Color(0xff297ae7), Color(0xff37e5ff)],
            stops: [0, .63, 1],
          ).createShader(Rect.fromLTRB(0, 0, cx - 360, y)),
      );
      for (final shift in [0.0, 9.0]) {
        final rail = Path()
          ..moveTo(12, y * .57 + shift)
          ..lineTo(cx - 499, y * .31 + shift)
          ..lineTo(cx - 425, y * .31 + shift)
          ..lineTo(cx - 367, y * .82 + shift);
        canvas.drawPath(
          rail,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(
              0xff53c9ff,
            ).withValues(alpha: shift == 0 ? .70 : .26)
            ..strokeWidth = 1.5,
        );
      }
    }

    wing();
    canvas.save();
    canvas.translate(size.width, 0);
    canvas.scale(-1, 1);
    wing();
    canvas.restore();
    canvas.drawRect(
      Rect.fromLTWH(15, y - 2, size.width - 30, 1.5),
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.transparent, Color(0xff53e5ff), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, 0, size.width, y)),
    );
  }

  @override
  bool shouldRepaint(covariant _TitleWings oldDelegate) => false;
}
