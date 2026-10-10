import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../shared/api.dart';
import 'catalog.dart';
import 'controller.dart';
import 'model.dart';
import 'materials.dart';
import 'scene.dart';
import 'viewport.dart';

enum _ResizeHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left;

  bool get movesLeft =>
      this == _ResizeHandle.topLeft ||
      this == _ResizeHandle.left ||
      this == _ResizeHandle.bottomLeft;
  bool get movesRight =>
      this == _ResizeHandle.topRight ||
      this == _ResizeHandle.right ||
      this == _ResizeHandle.bottomRight;
  bool get movesTop =>
      this == _ResizeHandle.topLeft ||
      this == _ResizeHandle.top ||
      this == _ResizeHandle.topRight;
  bool get movesBottom =>
      this == _ResizeHandle.bottomLeft ||
      this == _ResizeHandle.bottom ||
      this == _ResizeHandle.bottomRight;
  MouseCursor get cursor => switch (this) {
    _ResizeHandle.left ||
    _ResizeHandle.right => SystemMouseCursors.resizeLeftRight,
    _ResizeHandle.top ||
    _ResizeHandle.bottom => SystemMouseCursors.resizeUpDown,
    _ResizeHandle.topLeft ||
    _ResizeHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    _ResizeHandle.topRight ||
    _ResizeHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };
}

Map<_ResizeHandle, Offset> _resizePositions(Rect r) => {
  _ResizeHandle.topLeft: r.topLeft,
  _ResizeHandle.top: r.topCenter,
  _ResizeHandle.topRight: r.topRight,
  _ResizeHandle.right: r.centerRight,
  _ResizeHandle.bottomRight: r.bottomRight,
  _ResizeHandle.bottom: r.bottomCenter,
  _ResizeHandle.bottomLeft: r.bottomLeft,
  _ResizeHandle.left: r.centerLeft,
};

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
    this.onInteractionStart,
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
  final VoidCallback? onInteractionStart;
  final ValueChanged<String>? onError;
  @override
  State<ProcessCanvas> createState() => ProcessCanvasState();
}

class ProcessCanvasState extends State<ProcessCanvas> {
  final focus = FocusNode(debugLabel: '工艺画布');
  Offset pan = const Offset(24, 24);
  double zoom = 0.6;
  Size viewport = Size.zero;
  Size _lastCanvasSize = Size.zero;
  bool _automaticFit = true;
  Offset? _pointerStart, _panStart;
  ScreenElement? _dragStart;
  ScreenElement? _drawing;
  Offset? _drawingAnchor;
  int? _vertex;
  _ResizeHandle? _resizeHandle, _hoverHandle;
  bool _panning = false;
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
      cancelInteraction();
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
      _automaticFit = true;
      final next = ProcessViewport.fit(
        Size(document.width, document.height),
        viewport,
        padding: 24,
      );
      zoom = next.scale;
      pan = next.offset;
    });
  }

  void zoomBy(double factor, {Offset? at}) {
    final point = at ?? viewport.center(Offset.zero), scene = toScene(point);
    setState(() {
      _automaticFit = false;
      zoom = (zoom * factor).clamp(0.01, 4);
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

  _ResizeHandle? _resizeHandleAt(Offset scene) {
    final n = editor.selected;
    if (!editable || n == null || n.kind == 'pipe') return null;
    final rect = n.rect, tolerance = 7 / zoom;
    final handles = _resizePositions(rect);
    for (final h in [
      _ResizeHandle.topLeft,
      _ResizeHandle.topRight,
      _ResizeHandle.bottomLeft,
      _ResizeHandle.bottomRight,
    ]) {
      if ((handles[h]! - scene).distance <= tolerance) return h;
    }
    if (scene.dx >= rect.left - tolerance &&
        scene.dx <= rect.right + tolerance) {
      if ((scene.dy - rect.top).abs() <= tolerance) return _ResizeHandle.top;
      if ((scene.dy - rect.bottom).abs() <= tolerance) {
        return _ResizeHandle.bottom;
      }
    }
    if (scene.dy >= rect.top - tolerance &&
        scene.dy <= rect.bottom + tolerance) {
      if ((scene.dx - rect.left).abs() <= tolerance) return _ResizeHandle.left;
      if ((scene.dx - rect.right).abs() <= tolerance) {
        return _ResizeHandle.right;
      }
    }
    return null;
  }

  void clearPointer() {
    _pointerID = null;
    _pointerStart = null;
    _dragStart = null;
    _drawing = null;
    _drawingAnchor = null;
    _vertex = null;
    _resizeHandle = null;
    _hoverHandle = null;
    _panning = false;
  }

  void cancelInteraction() {
    if (_dragStart != null) editor.cancelGesture();
    clearPointer();
  }

  void down(PointerDownEvent event) {
    if (_pointerID != null) return;
    // Commit inspector drafts while the original element is still selected.
    widget.onInteractionStart?.call();
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
    if (event.buttons != kPrimaryMouseButton) {
      clearPointer();
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
      if ({'rect', 'ellipse', 'text', 'value'}.contains(widget.tool) ||
          widget.tool == 'symbol' && widget.symbol != null) {
        _drawingAnchor = editor.snapPoint(scene);
        setState(
          () => _drawing = ScreenElement.create(
            widget.tool,
            _drawingAnchor!,
            symbol: widget.symbol?.id ?? '',
          ).update({'width': 0.0, 'height': 0.0}),
        );
      }
      return;
    }
    _vertex = null;
    _resizeHandle = null;
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
        _resizeHandle = _resizeHandleAt(scene);
      }
    }
    if (_vertex == null && _resizeHandle == null) {
      editor.select(hit(scene)?.id ?? '');
    }
    final n = editor.selected;
    _dragStart = n?.kind == 'pipe' ? n!.withPoints(document.pipePoints(n)) : n;
    if (_dragStart != null) editor.beginGesture();
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != _pointerID || _pointerStart == null) return;
    if (_panning) {
      _automaticFit = false;
      setState(() => pan = _panStart! + (event.localPosition - _pointerStart!));
      return;
    }
    if (_drawing != null) {
      final rect = Rect.fromPoints(
        _drawingAnchor!,
        editor.snapPoint(toScene(event.localPosition)),
      );
      setState(
        () => _drawing = _drawing!.update({
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        }),
      );
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
    } else if (_resizeHandle != null) {
      final h = _resizeHandle!;
      final position = editor.snapPoint(
        _resizePositions(n.rect)[h]! +
            toScene(event.localPosition) -
            _pointerStart!,
      );
      final rect = Rect.fromLTRB(
        h.movesLeft ? position.dx.clamp(0, n.rect.right - 8) : n.x,
        h.movesTop ? position.dy.clamp(0, n.rect.bottom - 8) : n.y,
        h.movesRight
            ? position.dx.clamp(n.x + 8, document.width)
            : n.rect.right,
        h.movesBottom
            ? position.dy.clamp(n.y + 8, document.height)
            : n.rect.bottom,
      );
      editor.gestureUpdate(
        n.update({
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
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
    final drawing = _drawing, anchor = _drawingAnchor;
    if (_dragStart != null) editor.endGesture();
    clearPointer();
    if (drawing != null && editable) {
      if (drawing.width >= 8 && drawing.height >= 8) {
        perform(() => editor.add(drawing));
        widget.onToolDone();
      } else if ((toScene(event.localPosition) - anchor!).distance * zoom < 3 &&
          {'text', 'value', 'symbol'}.contains(drawing.kind)) {
        place(drawing.kind, anchor, symbol: widget.symbol);
      }
    }
    setState(() {});
  }

  void cancel(PointerCancelEvent event) {
    if (event.pointer != _pointerID) return;
    cancelInteraction();
    setState(() {});
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
      cancelInteraction();
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

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: LayoutBuilder(
      builder: (context, box) {
        final resized = viewport != box.biggest;
        viewport = box.biggest;
        final size = Size(document.width, document.height);
        if (_documentID != document.id ||
            _lastCanvasSize != size ||
            resized && _automaticFit) {
          _documentID = document.id;
          _lastCanvasSize = size;
          _automaticFit = true;
          final next = ProcessViewport.fit(size, viewport, padding: 24);
          zoom = next.scale;
          pan = next.offset;
        }
        if (viewport.isEmpty) return const SizedBox.shrink();
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
            widget.onInteractionStart?.call();
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
                ? (_resizeHandle ?? _hoverHandle)?.cursor ??
                      SystemMouseCursors.basic
                : SystemMouseCursors.precise,
            onHover: (event) {
              if (widget.tool == 'select') {
                final next = _resizeHandleAt(toScene(event.localPosition));
                if (next != _hoverHandle) setState(() => _hoverHandle = next);
              }
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
              onPointerCancel: cancel,
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
                            child: ProcessScene(
                              document: document,
                              symbols: widget.symbols,
                              definitions: widget.definitions,
                              live: widget.live,
                              online: widget.online,
                              overlays: [
                                if (editor.grid && editor.editing)
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _GridPainter(),
                                      ),
                                    ),
                                  ),
                                if (_drawing != null &&
                                    _drawing!.width >= 8 &&
                                    _drawing!.height >= 8)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Opacity(
                                        opacity: 0.65,
                                        child: Stack(
                                          children: [
                                            ProcessScene(
                                              document: document,
                                              symbols: widget.symbols,
                                              definitions: widget.definitions,
                                              live: widget.live,
                                              online: widget.online,
                                            ).element(_drawing!),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                if (pending.isNotEmpty)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: ProcessPipePainter(
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
                            '${(zoom * 100).round()}%  ·  ${document.width.toInt()} × ${document.height.toInt()}  ·  ${widget.tool == 'pipe'
                                ? '单击转折 · Enter/完成结束 · Esc 取消'
                                : {'rect', 'ellipse', 'text', 'value', 'symbol'}.contains(widget.tool)
                                ? '按住左键拖动绘制 · 松开完成 · Esc 取消'
                                : '滚轮缩放 · 中键/手形平移'}',
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
      for (final point in _resizePositions(node.rect).values) {
        final handle = Rect.fromCenter(
          center: point,
          width: 8 / zoom,
          height: 8 / zoom,
        );
        canvas.drawRect(handle, Paint()..color = Colors.white);
        canvas.drawRect(handle, p);
      }
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
      for (final side in document.ports(n)) {
        canvas.drawCircle(document.port(n.id, side), 4 / zoom, p);
      }
    }
  }

  @override
  bool shouldRepaint(_PortsPainter old) => true;
}
