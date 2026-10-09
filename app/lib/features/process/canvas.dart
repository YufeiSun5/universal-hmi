import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../shared/api.dart';
import 'catalog.dart';
import 'controller.dart';
import 'model.dart';
import 'materials.dart';

class ProcessCanvas extends StatefulWidget {
  const ProcessCanvas({
    super.key,
    required this.controller,
    required this.symbols,
    required this.definitions,
    required this.live,
    required this.online,
    this.enabled = true,
    required this.tool,
    required this.onToolDone,
    required this.onSave,
    this.symbol,
    this.onError,
    this.material,
    this.onMaterialPlaced,
  });
  final ProcessController controller;
  final Map<String, ProcessSymbol> symbols;
  final Map<String, Json> definitions, live;
  final bool online, enabled;
  final String tool;
  final ProcessSymbol? symbol;
  final ProcessMaterialSummary? material;
  final void Function(ProcessMaterialSummary, Offset)? onMaterialPlaced;
  final VoidCallback onToolDone, onSave;
  final ValueChanged<String>? onError;
  @override
  State<ProcessCanvas> createState() => ProcessCanvasState();
}

class ProcessCanvasState extends State<ProcessCanvas> {
  final focus = FocusNode(debugLabel: '工艺画布');
  Offset pan = const Offset(24, 24);
  double zoom = 0.6;
  Size viewport = Size.zero;
  Offset? _pointerStart, _panStart;
  ScreenElement? _dragStart;
  int? _vertex;
  bool _resizing = false, _panning = false;
  int? _pointerID;
  final pending = <Offset>[];
  Offset? hover;
  (String, String, Offset)? _startConnection;
  String _documentID = '';
  ProcessController get editor => widget.controller;
  bool get editable => editor.editing && widget.enabled;
  ScreenDocument get document => editor.document;
  Offset toScene(Offset p) => (p - pan) / zoom;
  Offset get center => editor.snapPoint(toScene(viewport.center(Offset.zero)));
  @override
  void initState() {
    super.initState();
    editor.addListener(changed);
  }

  @override
  void dispose() {
    editor.removeListener(changed);
    focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ProcessCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool != widget.tool || !editable) {
      pending.clear();
      hover = null;
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void fit() {
    if (viewport.isEmpty) return;
    setState(() {
      zoom = math
          .min(
            (viewport.width - 48) / document.width,
            (viewport.height - 48) / document.height,
          )
          .clamp(0.1, 4);
      pan = Offset(
        (viewport.width - document.width * zoom) / 2,
        (viewport.height - document.height * zoom) / 2,
      );
    });
  }

  void zoomBy(double factor, {Offset? at}) {
    final point = at ?? viewport.center(Offset.zero), scene = toScene(point);
    setState(() {
      zoom = (zoom * factor).clamp(0.1, 4);
      pan = point - scene * zoom;
    });
  }

  void cancelPipe() {
    setState(() {
      pending.clear();
      hover = null;
      _startConnection = null;
    });
  }

  void finishPipe() {
    if (!editable || pending.length < 2) return;
    final end = editor.connection(pending.last, 12 / zoom);
    perform(
      () => editor.addPipe(List.of(pending), start: _startConnection, end: end),
    );
    cancelPipe();
    widget.onToolDone();
  }

  List<Offset> segment(Offset a, Offset b) {
    if (!editor.orthogonal || a.dx == b.dx || a.dy == b.dy) return [b];
    return [
      (b.dx - a.dx).abs() >= (b.dy - a.dy).abs()
          ? Offset(b.dx, a.dy)
          : Offset(a.dx, b.dy),
      b,
    ];
  }

  void pipeClick(Offset scene) {
    final connection = editor.connection(scene, 12 / zoom),
        target = connection?.$3 ?? editor.snapPoint(scene);
    if (pending.isEmpty) {
      _startConnection = connection;
      pending.add(target);
    } else {
      for (final p in segment(pending.last, target)) {
        if (p != pending.last) pending.add(p);
      }
      if (pending.length >= 126 || connection != null) finishPipe();
    }
    setState(() {});
  }

  ScreenElement? hit(Offset position) {
    for (final n in document.nodes.reversed) {
      if (n.kind != 'pipe') {
        if (n.rect.inflate(3 / zoom).contains(position)) return n;
        continue;
      }
      final points = document.pipePoints(n);
      for (var i = 1; i < points.length; i++) {
        final a = points[i - 1], b = points[i], delta = b - a;
        final t = delta.distanceSquared == 0
            ? 0.0
            : (((position - a).dx * delta.dx + (position - a).dy * delta.dy) /
                      delta.distanceSquared)
                  .clamp(0.0, 1.0);
        if ((position - (a + delta * t)).distance <=
            math.max(n.strokeWidth / 2, 7 / zoom)) {
          return n;
        }
      }
    }
    return null;
  }

  void place(String kind, Offset scene, {ProcessSymbol? symbol}) {
    final position = editor.snapPoint(scene),
        n = ScreenElement.create(kind, position, symbol: symbol?.id ?? '');
    perform(
      () => editor.add(
        n.update({
          'x': math.min(position.dx, document.width - n.width),
          'y': math.min(position.dy, document.height - n.height),
        }),
      ),
    );
    widget.onToolDone();
  }

  void perform(VoidCallback action) {
    try {
      action();
    } catch (e) {
      widget.onError?.call(e.toString());
    }
  }

  void down(PointerDownEvent event) {
    if (_pointerID != null) return;
    focus.requestFocus();
    _pointerID = event.pointer;
    final scene = toScene(event.localPosition);
    if (event.buttons == kSecondaryMouseButton && editable) {
      editor.select(hit(scene)?.id ?? '');
      contextMenu(event.position);
      _pointerID = null;
      return;
    }
    _pointerStart = scene;
    _panStart = pan;
    _panning =
        widget.tool == 'hand' ||
        !editable ||
        event.buttons == kMiddleMouseButton ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.space,
        );
    if (_panning) {
      _pointerStart = event.localPosition;
      return;
    }
    if (widget.tool == 'pipe') {
      pipeClick(scene);
      return;
    }
    if (widget.tool != 'select') {
      if (widget.tool == 'material' && widget.material != null) {
        widget.onMaterialPlaced?.call(
          widget.material!,
          editor.snapPoint(scene),
        );
        widget.onToolDone();
      }
      if (widget.tool == 'symbol' && widget.symbol != null) {
        place('symbol', scene, symbol: widget.symbol);
      }
      if ({'rect', 'ellipse', 'text', 'value'}.contains(widget.tool)) {
        place(widget.tool, scene);
      }
      return;
    }
    _vertex = null;
    _resizing = false;
    final selected = editor.selected;
    if (selected != null) {
      if (selected.kind == 'pipe') {
        final points = document.pipePoints(selected);
        for (var i = 0; i < points.length; i++) {
          if ((points[i] - scene).distance < 9 / zoom) {
            _vertex = i;
            break;
          }
        }
      } else {
        _resizing = (selected.rect.bottomRight - scene).distance < 11 / zoom;
      }
    }
    if (_vertex == null && !_resizing) editor.select(hit(scene)?.id ?? '');
    final n = editor.selected;
    _dragStart = n?.kind == 'pipe' ? n!.withPoints(document.pipePoints(n)) : n;
    if (_dragStart != null) editor.beginGesture();
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != _pointerID || _pointerStart == null) return;
    if (_panning) {
      setState(() => pan = _panStart! + (event.localPosition - _pointerStart!));
      return;
    }
    final n = _dragStart;
    if (n == null || widget.tool != 'select') return;
    final scene = editor.snapPoint(toScene(event.localPosition));
    if (_vertex != null) {
      final points = n.points, index = _vertex!;
      points[index] = scene;
      final changes = <String, dynamic>{};
      if (index == 0) {
        changes.addAll({'start_node': '', 'start_port': ''});
      }
      if (index == points.length - 1) {
        changes.addAll({'end_node': '', 'end_port': ''});
      }
      editor.gestureUpdate(n.withPoints(points, changes: changes));
    } else if (_resizing) {
      editor.gestureUpdate(
        n.update({
          'width': (scene.dx - n.x).clamp(8, document.width - n.x),
          'height': (scene.dy - n.y).clamp(8, document.height - n.y),
        }),
      );
    } else {
      final target = editor.snapPoint(
        n.rect.topLeft + toScene(event.localPosition) - _pointerStart!,
      );
      final delta = Offset(
        (target.dx - n.x).clamp(-n.x, document.width - n.rect.right),
        (target.dy - n.y).clamp(-n.y, document.height - n.rect.bottom),
      );
      editor.gestureUpdate(n.moved(delta));
    }
  }

  void up(PointerEvent event) {
    if (event.pointer != _pointerID) return;
    if (_dragStart != null) editor.endGesture();
    _pointerID = null;
    _pointerStart = null;
    _dragStart = null;
    _vertex = null;
    _resizing = false;
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey,
        ctrl =
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
    if (key == LogicalKeyboardKey.escape) {
      cancelPipe();
      editor.select('');
      widget.onToolDone();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && widget.tool == 'pipe') {
      finishPipe();
      return KeyEventResult.handled;
    }
    if (!editable) return KeyEventResult.ignored;
    if (ctrl && key == LogicalKeyboardKey.keyS) {
      widget.onSave();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      HardwareKeyboard.instance.isShiftPressed ? editor.redo() : editor.undo();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyY) {
      editor.redo();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      editor.copy();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      perform(editor.paste);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyD) {
      editor.copy();
      perform(editor.paste);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      editor.removeSelected();
      return KeyEventResult.handled;
    }
    final step = HardwareKeyboard.instance.isShiftPressed
        ? 10.0
        : editor.snap
        ? 10.0
        : 1.0;
    final delta = {
      LogicalKeyboardKey.arrowLeft: Offset(-step, 0),
      LogicalKeyboardKey.arrowRight: Offset(step, 0),
      LogicalKeyboardKey.arrowUp: Offset(0, -step),
      LogicalKeyboardKey.arrowDown: Offset(0, step),
    }[key];
    if (delta != null) {
      editor.move(delta);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> contextMenu(Offset point) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final entry in {
          'copy': '复制',
          'paste': '粘贴',
          'front': '置于顶层',
          'back': '置于底层',
          'delete': '删除',
        }.entries)
          PopupMenuItem(
            value: entry.key,
            enabled: entry.key == 'paste' || editor.selected != null,
            child: Text(entry.value),
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        editor.copy();
      case 'paste':
        perform(editor.paste);
      case 'front':
        editor.layer(true);
      case 'back':
        editor.layer(false);
      case 'delete':
        editor.removeSelected();
    }
  }

  Color stateColor(ScreenElement n) {
    if (n.pointID.isEmpty) return n.color;
    final state = processValue(
      n,
      document,
      widget.definitions,
      widget.live,
      widget.online,
    );
    return state.good
        ? state.active
              ? n.color
              : const Color(0xff94a3b8)
        : state.quality == 'bad'
        ? const Color(0xffdc2626)
        : const Color(0xffb7791f);
  }

  Widget element(ScreenElement n) {
    final value = processValue(
      n,
      document,
      widget.definitions,
      widget.live,
      widget.online,
    );
    final symbol = widget.symbols[n.symbol];
    final color = stateColor(n);
    Widget content = switch (n.kind) {
      'symbol' =>
        symbol == null
            ? const Center(child: Text('素材缺失'))
            : SvgPicture.asset(
                symbol.path,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
      'image' =>
        document.assets[n.image] == null
            ? const Center(child: Text('图片缺失'))
            : Image.memory(
                document.assets[n.image]!.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Center(child: Text('图片无法读取')),
              ),
      'value' => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          value.text,
          key: Key('process-value-${n.id}'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: n.fontSize,
            color: value.good ? n.color : const Color(0xffb7791f),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      'text' => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          n.text,
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: n.fontSize, color: n.color),
        ),
      ),
      _ => CustomPaint(painter: _ShapePainter(n, color)),
    };
    if (n.rotation != 0) {
      content = RotatedBox(quarterTurns: n.rotation ~/ 90, child: content);
    }
    if (n.kind == 'symbol' && n.pointID.isNotEmpty && !value.good) {
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: const Color(0xe6ffffff),
              child: Text(
                value.text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xffb7791f)),
              ),
            ),
          ),
        ],
      );
    }
    return Positioned(
      left: n.x,
      top: n.y,
      width: n.width,
      height: n.height,
      child: Tooltip(
        message: n.pointID.isNotEmpty
            ? value.tooltip
            : n.text.isNotEmpty
            ? n.text
            : symbol?.name ?? n.kind,
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: LayoutBuilder(
      builder: (context, box) {
        viewport = box.biggest;
        if (_documentID != document.id) {
          _documentID = document.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) fit();
          });
        }
        final matrix = Matrix4.fromList([
          zoom,
          0,
          0,
          0,
          0,
          zoom,
          0,
          0,
          0,
          0,
          1,
          0,
          pan.dx,
          pan.dy,
          0,
          1,
        ]);
        return DragTarget<Object>(
          onWillAcceptWithDetails: (d) =>
              editable &&
              (d.data is ProcessSymbol || d.data is ProcessMaterialSummary),
          onAcceptWithDetails: (details) {
            final render = context.findRenderObject()! as RenderBox;
            final scene = editor.snapPoint(
              toScene(render.globalToLocal(details.offset)),
            );
            final item = details.data;
            if (item is ProcessSymbol) place('symbol', scene, symbol: item);
            if (item is ProcessMaterialSummary) {
              widget.onMaterialPlaced?.call(item, scene);
            }
          },
          builder: (context, _, _) => MouseRegion(
            cursor: _panning || widget.tool == 'hand'
                ? SystemMouseCursors.grab
                : widget.tool == 'select'
                ? SystemMouseCursors.basic
                : SystemMouseCursors.precise,
            onHover: (event) {
              if (widget.tool == 'pipe') {
                setState(
                  () => hover = editor.snapPoint(toScene(event.localPosition)),
                );
              }
            },
            child: Listener(
              key: const Key('process-canvas'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: down,
              onPointerMove: move,
              onPointerUp: up,
              onPointerCancel: up,
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) => zoomBy(
                      math.exp(-event.scrollDelta.dy / 600),
                      at: event.localPosition,
                    ),
                  );
                }
              },
              child: ClipRect(
                child: ColoredBox(
                  color: const Color(0xffe9edf3),
                  child: Stack(
                    children: [
                      OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: document.width,
                        maxWidth: document.width,
                        minHeight: document.height,
                        maxHeight: document.height,
                        child: Transform(
                          transform: matrix,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: document.width,
                            height: document.height,
                            child: Stack(
                              clipBehavior: Clip.hardEdge,
                              children: [
                                const Positioned.fill(
                                  child: ColoredBox(color: Colors.white),
                                ),
                                if (editor.grid && editor.editing)
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _GridPainter(),
                                      ),
                                    ),
                                  ),
                                for (final n in document.nodes)
                                  if (n.kind == 'pipe')
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          painter: _PipePainter(
                                            document.pipePoints(n),
                                            stateColor(n),
                                            n.strokeWidth,
                                            n.arrow,
                                          ),
                                          child:
                                              n.pointID.isNotEmpty &&
                                                  !processValue(
                                                    n,
                                                    document,
                                                    widget.definitions,
                                                    widget.live,
                                                    widget.online,
                                                  ).good
                                              ? Stack(
                                                  children: [
                                                    Positioned(
                                                      left: document
                                                          .pipePoints(n)
                                                          .first
                                                          .dx,
                                                      top:
                                                          document
                                                              .pipePoints(n)
                                                              .first
                                                              .dy +
                                                          5,
                                                      child: Text(
                                                        processValue(
                                                          n,
                                                          document,
                                                          widget.definitions,
                                                          widget.live,
                                                          widget.online,
                                                        ).text,
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                          color: Color(
                                                            0xffb7791f,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : null,
                                        ),
                                      ),
                                    )
                                  else
                                    element(n),
                                if (pending.isNotEmpty)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _PipePainter(
                                          [
                                            ...pending,
                                            if (hover != null)
                                              ...segment(pending.last, hover!),
                                          ],
                                          const Color(0xff2563eb),
                                          3,
                                          false,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (editor.editing && widget.tool == 'pipe')
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _PortsPainter(document, zoom),
                                      ),
                                    ),
                                  ),
                                if (editor.editing && editor.selected != null)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _SelectionPainter(
                                          document,
                                          editor.selected!,
                                          zoom,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        bottom: 8,
                        child: IgnorePointer(
                          child: Text(
                            '${(zoom * 100).round()}%  ·  ${document.width.toInt()} × ${document.height.toInt()}  ·  ${widget.tool == 'pipe' ? '单击转折 · Enter/完成结束 · Esc 取消' : '滚轮缩放 · 中键/手形平移'}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xff526176),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xffe5eaf1)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 10) {
      for (double y = 0; y < size.height; y += 10) {
        canvas.drawCircle(Offset(x, y), 0.8, p);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

class _PipePainter extends CustomPainter {
  _PipePainter(this.points, this.color, this.width, this.arrow);
  final List<Offset> points;
  final Color color;
  final double width;
  final bool arrow;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    if (arrow) {
      final end = points.last,
          previous = points[points.length - 2],
          direction = end - previous;
      if (direction.distance == 0) return;
      final unit = direction / direction.distance,
          normal = Offset(-unit.dy, unit.dx),
          length = math.max(10.0, width * 3);
      canvas.drawPath(
        Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(
            (end - unit * length + normal * length * .45).dx,
            (end - unit * length + normal * length * .45).dy,
          )
          ..lineTo(
            (end - unit * length - normal * length * .45).dx,
            (end - unit * length - normal * length * .45).dy,
          )
          ..close(),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_PipePainter old) => true;
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.node, this.color);
  final ScreenElement node;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(node.strokeWidth / 2);
    final p = Paint();
    if (node.fill != null) {
      p.color = node.fill!;
      node.kind == 'ellipse'
          ? canvas.drawOval(rect, p)
          : canvas.drawRect(rect, p);
    }
    p
      ..color = color
      ..strokeWidth = node.strokeWidth
      ..style = PaintingStyle.stroke;
    node.kind == 'ellipse'
        ? canvas.drawOval(rect, p)
        : canvas.drawRect(rect, p);
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.node != node || old.color != color;
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.document, this.node, this.zoom);
  final ScreenDocument document;
  final ScreenElement node;
  final double zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xff2563eb)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / zoom;
    if (node.kind == 'pipe') {
      for (final point in document.pipePoints(node)) {
        canvas.drawRect(
          Rect.fromCenter(center: point, width: 8 / zoom, height: 8 / zoom),
          Paint()..color = Colors.white,
        );
        canvas.drawRect(
          Rect.fromCenter(center: point, width: 8 / zoom, height: 8 / zoom),
          p,
        );
      }
    } else {
      canvas.drawRect(node.rect.inflate(2 / zoom), p);
      canvas.drawRect(
        Rect.fromCenter(
          center: node.rect.bottomRight,
          width: 9 / zoom,
          height: 9 / zoom,
        ),
        Paint()..color = const Color(0xff2563eb),
      );
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => true;
}

class _PortsPainter extends CustomPainter {
  _PortsPainter(this.document, this.zoom);
  final ScreenDocument document;
  final double zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xff0e7490);
    for (final n in document.nodes.where(
      (n) => !{'pipe', 'text', 'value'}.contains(n.kind),
    )) {
      for (final side in ['left', 'right', 'top', 'bottom']) {
        canvas.drawCircle(document.port(n.id, side), 4 / zoom, p);
      }
    }
  }

  @override
  bool shouldRepaint(_PortsPainter old) => true;
}
