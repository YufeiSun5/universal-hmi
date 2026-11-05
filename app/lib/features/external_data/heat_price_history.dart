import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';

String seasonLabel(int year) => '$year–${year + 1}';

class HeatPriceHistory extends StatefulWidget {
  const HeatPriceHistory({
    super.key,
    required this.api,
    required this.path,
    required this.initial,
    required this.year,
    required this.onChanged,
  });
  final PlatformApi api;
  final String path;
  final Json initial;
  final int year;
  final ValueChanged<Json> onChanged;
  @override
  State<HeatPriceHistory> createState() => _HeatPriceHistoryState();
}

class _HeatPriceHistoryState extends State<HeatPriceHistory> {
  late Json book = widget.initial;
  bool busy = false;
  String? error;
  List<Json> get items => objects(book['items']);

  Future<void> reload() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.api.request('GET', widget.path);
      if (!mounted) return;
      setState(() => book = next);
      widget.onChanged(next);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> edit() async {
    final year = TextEditingController(text: '${widget.year}');
    final price = TextEditingController(
      text:
          items
              .where((r) => r['year'] == widget.year)
              .firstOrNull?['unit_price']
              ?.toString() ??
          '',
    );
    final revision = book['revision'];
    String? issue;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('修改采暖季价格'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('保存后八个站、所有结算用户共用此价格。每个采暖季保留一份价格，可补录往年。'),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('heat-price-year'),
                    controller: year,
                    enabled: !saving,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '采暖季起始年',
                      hintText: '例如 2026：2026-11-05 至 2027-04-05',
                    ),
                    onChanged: (v) {
                      final y = int.tryParse(v);
                      price.text =
                          items
                              .where((r) => r['year'] == y)
                              .firstOrNull?['unit_price']
                              ?.toString() ??
                          '';
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('heat-price-value'),
                    controller: price,
                    enabled: !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '统一单价（元/GJ）'),
                  ),
                  if (issue != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        issue!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final y = int.tryParse(year.text.trim());
                      if (y == null ||
                          y < 1900 ||
                          y > 2100 ||
                          !RegExp(
                            r'^(0|[1-9][0-9]{0,7})(\.[0-9]{1,6})?$',
                          ).hasMatch(price.text.trim())) {
                        update(() => issue = '请填写1900～2100的起始年和有效单价（最多6位小数）');
                        return;
                      }
                      update(() {
                        saving = true;
                        issue = null;
                      });
                      try {
                        final next = await widget.api.request(
                          'POST',
                          widget.path,
                          body: {
                            'year': y,
                            'unit_price': price.text.trim(),
                            'revision': revision,
                          },
                        );
                        if (!mounted || !dialogContext.mounted) return;
                        next['can_edit'] = book['can_edit'];
                        setState(() => book = next);
                        widget.onChanged(next);
                        Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          update(() {
                            issue = '$e\n如价格已由他人修改，请取消后刷新，再核对保存。';
                            saving = false;
                          });
                        }
                      }
                    },
              child: Text(saving ? '保存中…' : '保存共享价格'),
            ),
          ],
        ),
      ),
    );
    // Controllers remain alive through the dialog's reverse transition.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    year.dispose();
    price.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('历年采暖季价格')),
        IconButton(
          tooltip: '刷新价格',
          onPressed: busy ? null : reload,
          icon: const Icon(Icons.refresh, size: 20),
        ),
        if (book['can_edit'] == true)
          PopupMenuButton<String>(
            tooltip: '价格操作',
            onSelected: (_) => edit(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('补录 / 修改价格')),
            ],
          ),
      ],
    ),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '八站统一 · 元/GJ · 每年11月5日至次年4月5日',
              style: TextStyle(fontSize: 12),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Text('尚未设置价格。可从右上角“价格操作”补录本季和往年单价。'),
              )
            else ...[
              const SizedBox(height: 12),
              SizedBox(height: 200, child: HeatPriceChart(items: items)),
              const Divider(),
              for (final p in items.reversed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${seasonLabel(p['year'] as int)} 采暖季'),
                  trailing: Text(
                    '${p['unit_price']} 元/GJ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
            if (book['can_edit'] != true)
              const Text(
                '当前入口只读；请在允许修改的本机入口维护价格。',
                style: TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class HeatPriceChart extends StatelessWidget {
  const HeatPriceChart({super.key, required this.items});
  final List<Json> items;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '历年价格曲线：${items.map((p) => '${seasonLabel(p['year'] as int)}，${p['unit_price']}元/GJ').join('；')}',
    child: CustomPaint(
      painter: _PricePainter(
        items,
        Theme.of(context).colorScheme.primary,
        Theme.of(context).colorScheme.onSurface,
      ),
      size: Size.infinite,
    ),
  );
}

class _PricePainter extends CustomPainter {
  _PricePainter(this.items, this.color, this.textColor);
  final List<Json> items;
  final Color color, textColor;
  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty || size.width < 100) return;
    final ordered = List<Json>.from(items)
      ..sort((a, b) => (a['year'] as int).compareTo(b['year'] as int));
    final first = ordered.first['year'] as int,
        last = ordered.last['year'] as int;
    final values = ordered
        .map((p) => double.parse('${p['unit_price']}'))
        .toList();
    final maxValue = math.max(1.0, values.reduce(math.max) * 1.2);
    final bounds = Rect.fromLTRB(48, 18, size.width - 24, size.height - 32);
    final grid = Paint()
      ..color = textColor.withValues(alpha: .15)
      ..strokeWidth = 1;
    void label(String text, Offset at, {bool center = false}) {
      final p = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: textColor, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      p.paint(
        canvas,
        Offset(
          (at.dx - (center ? p.width / 2 : 0)).clamp(
            0,
            math.max(0, size.width - p.width),
          ),
          at.dy,
        ),
      );
    }

    for (var i = 0; i <= 4; i++) {
      final y = bounds.bottom - bounds.height * i / 4;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), grid);
      label((maxValue * i / 4).toStringAsFixed(1), Offset(0, y - 6));
    }
    Offset? previous;
    int? previousYear;
    final stride = math.max(1, (ordered.length / (bounds.width / 78)).ceil());
    for (var i = 0; i < ordered.length; i++) {
      final year = ordered[i]['year'] as int;
      final x = first == last
          ? bounds.center.dx
          : bounds.left + bounds.width * (year - first) / (last - first);
      final p = Offset(x, bounds.bottom - bounds.height * values[i] / maxValue);
      // Missing seasons stay gaps, never interpolated prices.
      if (previous != null && year == previousYear! + 1) {
        canvas.drawLine(
          previous,
          p,
          Paint()
            ..color = color
            ..strokeWidth = 2,
        );
      }
      canvas.drawCircle(p, 3.5, Paint()..color = color);
      if (i % stride == 0 || i == ordered.length - 1) {
        label('$year', Offset(x, bounds.bottom + 8), center: true);
        label(
          '${ordered[i]['unit_price']}',
          Offset(x, p.dy - 17),
          center: true,
        );
      }
      previous = p;
      previousYear = year;
    }
  }

  @override
  bool shouldRepaint(covariant _PricePainter old) =>
      old.items != items || old.color != color || old.textColor != textColor;
}
