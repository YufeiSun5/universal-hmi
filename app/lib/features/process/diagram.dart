import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/theme.dart';
import 'catalog.dart';
import 'model.dart';
import 'scene.dart';
import 'viewport.dart';
import 'monitor_theme.dart';

class ProcessReadings {
  const ProcessReadings(this.definitions, this.live, this.online);
  final Map<String, Json> definitions, live;
  final bool online;
}

/// A bounded, read-only component. The host supplies data and owns polling.
/// It never saves, selects editor elements, connects devices, or changes a draft.
class ProcessDiagram extends StatefulWidget {
  const ProcessDiagram({
    super.key,
    required this.document,
    required this.definitions,
    required this.live,
    required this.online,
    this.symbols,
    this.title,
    this.dark = false,
    this.compactUnboundValues = false,
    this.showControls = true,
  });
  final ScreenDocument document;
  final Map<String, Json> definitions, live;
  final bool online;
  final Map<String, ProcessSymbol>? symbols;
  final String? title;
  final bool dark;
  final bool compactUnboundValues;
  final bool showControls;
  @override
  State<ProcessDiagram> createState() => _ProcessDiagramState();
}

class _ProcessDiagramState extends State<ProcessDiagram> {
  late final loadedSymbols = processSymbols;
  bool variables = false;
  double factor = 1;
  Offset pan = Offset.zero;
  Size lastViewport = Size.zero, lastScene = Size.zero;
  String lastID = '';
  void reset() => setState(() {
    factor = 1;
    pan = Offset.zero;
  });
  Widget controls() => Container(
    height: 32,
    padding: const EdgeInsets.only(left: 8),
    decoration: BoxDecoration(
      color: widget.dark ? MonitorColors.panel : WorkbenchColors.chrome,
      border: Border(
        bottom: BorderSide(
          color: widget.dark ? MonitorColors.line : WorkbenchColors.line,
        ),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            widget.title ?? widget.document.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        if (!variables) ...[
          IconButton(
            key: const Key('diagram-zoom-out'),
            tooltip: '缩小',
            onPressed: factor <= 1
                ? null
                : () => setState(() => factor = math.max(1, factor / 1.4)),
            icon: const Icon(Icons.remove, size: 14),
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
          ),
          IconButton(
            key: const Key('diagram-fit'),
            tooltip: '适应组件',
            onPressed: reset,
            icon: const Icon(Icons.fit_screen, size: 15),
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
          ),
          IconButton(
            key: const Key('diagram-zoom-in'),
            tooltip: '放大，拖动查看',
            onPressed: factor >= 6
                ? null
                : () => setState(() => factor = math.min(6, factor * 1.4)),
            icon: const Icon(Icons.add, size: 14),
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
          ),
        ],
        TextButton(
          key: const Key('diagram-variables'),
          onPressed: () => setState(() => variables = !variables),
          child: Text(
            variables ? '工艺图' : '变量表',
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    ),
  );
  Widget readings() {
    final nodes = widget.document.nodes
        .where((n) => n.kind == 'value')
        .toList();
    return nodes.isEmpty
        ? const Center(child: Text('模板没有实时变量'))
        : ListView.separated(
            key: const Key('diagram-variable-list'),
            itemCount: nodes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final n = nodes[i],
                  value = processValue(
                    n,
                    widget.document,
                    widget.definitions,
                    widget.live,
                    widget.online,
                  );
              final label = n.label.isNotEmpty
                  ? n.label
                  : widget.definitions[n.pointID]?['name']?.toString() ??
                        (n.text.isNotEmpty ? n.text : '变量 ${i + 1}');
              final unit = n.unitOverride.isNotEmpty
                  ? n.unitOverride
                  : widget.definitions[n.pointID]?['unit']?.toString() ?? '';
              return Tooltip(
                message: value.tooltip,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '${value.text}${(!n.showUnit || !value.good) && unit.isNotEmpty ? ' $unit' : ''}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 13,
                            color: widget.dark
                                ? value.good
                                      ? MonitorColors.text
                                      : MonitorColors.warning
                                : value.good
                                ? WorkbenchColors.ink
                                : WorkbenchColors.amber,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
  }

  Widget drawing(Map<String, ProcessSymbol> symbols) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest,
          scene = Size(widget.document.width, widget.document.height);
      if (size.isEmpty) return const SizedBox.shrink();
      if (lastViewport != size ||
          lastScene != scene ||
          lastID != widget.document.id) {
        lastViewport = size;
        lastScene = scene;
        lastID = widget.document.id;
        factor = 1;
        pan = Offset.zero;
      }
      final fit = ProcessViewport.fit(scene, size);
      final scale = fit.scale * factor;
      final offset =
          Offset(
            (size.width - scene.width * scale) / 2,
            (size.height - scene.height * scale) / 2,
          ) +
          pan;
      final matrix = Matrix4.fromList([
        scale,
        0,
        0,
        0,
        0,
        scale,
        0,
        0,
        0,
        0,
        1,
        0,
        offset.dx,
        offset.dy,
        0,
        1,
      ]);
      final minFont = widget.document.nodes
          .where((n) => n.kind == 'text' || n.kind == 'value')
          .fold<double>(128, (font, n) => math.min(font, n.fontSize));
      return GestureDetector(
        onPanUpdate: factor > 1
            ? (event) => setState(() => pan += event.delta)
            : null,
        child: ClipRect(
          key: const Key('diagram-viewport'),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.white),
            child: Stack(
              children: [
                OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: scene.width,
                  maxWidth: scene.width,
                  minHeight: scene.height,
                  maxHeight: scene.height,
                  child: Transform(
                    transform: matrix,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      key: const Key('diagram-scene'),
                      width: scene.width,
                      height: scene.height,
                      child: ProcessScene(
                        document: widget.document,
                        symbols: symbols,
                        definitions: widget.definitions,
                        live: widget.live,
                        online: widget.online,
                        compactUnboundValues: widget.compactUnboundValues,
                        invalidColor: widget.dark
                            ? MonitorColors.warning
                            : const Color(0xffb7791f),
                      ),
                    ),
                  ),
                ),
                if (widget.showControls &&
                    minFont * fit.scale < 11 &&
                    factor == 1)
                  Positioned(
                    left: 4,
                    right: 4,
                    bottom: 2,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: widget.dark
                            ? MonitorColors.panel
                            : const Color(0xedffffff),
                        child: Text(
                          '文字已缩小，可切换变量表或放大查看',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            color: widget.dark
                                ? MonitorColors.muted
                                : WorkbenchColors.muted,
                          ),
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
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final height = box.hasBoundedHeight
          ? box.maxHeight
          : box.maxWidth * widget.document.height / widget.document.width +
                (widget.showControls ? 32 : 0);
      if (!height.isFinite || height <= 0 || box.maxWidth <= 0) {
        return const SizedBox.shrink();
      }
      return SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showControls) controls(),
            Expanded(
              child: variables
                  ? readings()
                  : widget.symbols != null
                  ? drawing(widget.symbols!)
                  : FutureBuilder<List<ProcessSymbol>>(
                      future: loadedSymbols,
                      builder: (_, snapshot) => snapshot.hasError
                          ? const Center(child: Text('素材读取失败'))
                          : !snapshot.hasData
                          ? const Center(child: CircularProgressIndicator())
                          : drawing({for (final s in snapshot.data!) s.id: s}),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
