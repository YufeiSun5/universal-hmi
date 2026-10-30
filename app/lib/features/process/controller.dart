import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';
import 'pipe_drawing.dart';
import 'presentation.dart';

class ProcessController extends ChangeNotifier {
  ProcessController(this.document);
  ScreenDocument document;
  ScreenDocument? _saved;
  String selectedID = '';
  final Set<String> selectedIDs = {};
  List<ScreenElement> get selection =>
      document.nodes.where((n) => selectedIDs.contains(n.id)).toList();
  bool grid = true, snap = true, smartGuides = true, editing = true;
  PipeDrawingMode pipeMode = PipeDrawingMode.orthogonal;
  double pipeAngleStep = 15;
  bool get orthogonal => pipeMode == PipeDrawingMode.orthogonal;
  set orthogonal(bool value) =>
      pipeMode = value ? PipeDrawingMode.orthogonal : PipeDrawingMode.free;
  final _undo = <ScreenDocument>[], _redo = <ScreenDocument>[];
  ScreenDocument? _gesture;
  List<ScreenElement> _clipboard = [];
  Map<String, EmbeddedImage> _clipboardAssets = {};
  ScreenElement? get selected =>
      document.nodes.where((n) => n.id == selectedID).firstOrNull;
  bool get dirty =>
      _saved == null ||
      document.name != _saved!.name ||
      document.station != _saved!.station ||
      document.width != _saved!.width ||
      document.height != _saved!.height ||
      !mapEquals(document.background, _saved!.background) ||
      !listEquals(document.nodes, _saved!.nodes) ||
      !mapEquals(document.assets, _saved!.assets);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void open(ScreenDocument next, {bool saved = true}) {
    if (next.kind != 'process') {
      throw const FormatException('GIS 画面请在 GIS 模块打开');
    }
    document = next;
    _saved = saved ? next : null;
    selectedID = '';
    selectedIDs.clear();
    _undo.clear();
    _redo.clear();
    _gesture = null;
    _clipboard = [];
    _clipboardAssets = {};
    notifyListeners();
  }

  void saved(int revision, {ScreenDocument? snapshot}) {
    if (snapshot != null && document.id != snapshot.id) return;
    document = document.copy(revision: revision);
    _saved = snapshot?.copy(revision: revision) ?? document;
    notifyListeners();
  }

  void select(String id) {
    selectMany(id.isEmpty ? {} : {id});
  }

  void selectMany(Set<String> ids) {
    selectedIDs
      ..clear()
      ..addAll(ids);
    selectedID = selectedIDs.length == 1 ? selectedIDs.first : '';
    notifyListeners();
  }

  void toggleSelection(String id) {
    final ids = {...selectedIDs};
    if (!ids.add(id)) ids.remove(id);
    selectMany(ids);
  }

  void selectAll() => selectMany(
    document.nodes
        .where((n) => !ProcessPresentation.omitBackdrop(document, n))
        .map((n) => n.id)
        .toSet(),
  );

  void commit(ScreenDocument next) {
    if (!editing || identical(next, document)) return;
    _undo.add(document);
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
    document = next;
    notifyListeners();
  }

  void undo() {
    if (!editing || !canUndo) return;
    _redo.add(document);
    document = _undo.removeLast().copy(revision: document.revision);
    selectedID = '';
    selectedIDs.clear();
    notifyListeners();
  }

  void redo() {
    if (!editing || !canRedo) return;
    _undo.add(document);
    document = _redo.removeLast().copy(revision: document.revision);
    selectedID = '';
    selectedIDs.clear();
    notifyListeners();
  }

  void update(ScreenElement node) => commit(
    document.copy(
      nodes: [for (final n in document.nodes) n.id == node.id ? node : n],
    ),
  );
  void add(ScreenElement node, {Map<String, EmbeddedImage>? assets}) {
    if (!editing) return;
    if (document.nodes.length >= 1000) {
      throw const FormatException('每个画面最多 1000 个元素');
    }
    commit(
      document.copy(
        nodes: [...document.nodes, node],
        assets: assets ?? document.assets,
      ),
    );
    select(node.id);
  }

  Offset snapPoint(Offset p) => Offset(
    (snap ? (p.dx / 10).round() * 10.0 : p.dx).clamp(0, document.width),
    (snap ? (p.dy / 10).round() * 10.0 : p.dy).clamp(0, document.height),
  );
  void removeSelected() {
    if (!editing) return;
    final removed = {...selectedIDs};
    if (removed.isEmpty) return;
    final nodes = <ScreenElement>[];
    for (final n in document.nodes) {
      if (removed.contains(n.id)) continue;
      nodes.add(
        n.kind == 'pipe'
            ? n.withPoints(
                document.pipePoints(n),
                changes: {
                  if (removed.contains(n.startNode)) 'start_node': '',
                  if (removed.contains(n.startNode)) 'start_port': '',
                  if (removed.contains(n.endNode)) 'end_node': '',
                  if (removed.contains(n.endNode)) 'end_port': '',
                },
              )
            : n,
      );
    }
    final used = nodes
        .where((n) => n.kind == 'image')
        .map((n) => n.image)
        .toSet();
    if (document.background?['type'] == 'image') {
      used.add(document.background!['image'] as String);
    }
    commit(
      document.copy(
        nodes: nodes,
        assets: Map.fromEntries(
          document.assets.entries.where((a) => used.contains(a.key)),
        ),
      ),
    );
    selectedID = '';
    selectedIDs.clear();
    notifyListeners();
  }

  void copy() {
    _clipboard = selection
        .map((n) => n.kind == 'pipe' ? n.withPoints(document.pipePoints(n)) : n)
        .toList();
    _clipboardAssets = Map.fromEntries(
      document.assets.entries.where(
        (a) => _clipboard.any((n) => n.kind == 'image' && n.image == a.key),
      ),
    );
  }

  void paste() {
    if (!editing || _clipboard.isEmpty) return;
    if (document.nodes.length + _clipboard.length > 1000) {
      throw const FormatException('每个画面最多 1000 个元素');
    }
    final ids = {for (final n in _clipboard) n.id: screenIdentity()};
    final right = _clipboard.map((n) => n.rect.right).reduce(math.max);
    final bottom = _clipboard.map((n) => n.rect.bottom).reduce(math.max);
    final shift = Offset(
      math.max(0, math.min(20, document.width - right)),
      math.max(0, math.min(20, document.height - bottom)),
    );
    final copies = _clipboard.map((n) {
      var copy = n.moved(shift).update({'id': ids[n.id]});
      if (n.kind == 'pipe') {
        copy = copy.update({
          'start_node': ids[n.startNode] ?? '',
          'start_port': ids.containsKey(n.startNode) ? n.startPort : '',
          'end_node': ids[n.endNode] ?? '',
          'end_port': ids.containsKey(n.endNode) ? n.endPort : '',
        });
      }
      return copy;
    }).toList();
    commit(
      document.copy(
        nodes: [...document.nodes, ...copies],
        assets: {...document.assets, ..._clipboardAssets},
      ),
    );
    selectMany(ids.values.toSet());
  }

  void gestureMoveSelection(Offset delta) {
    if (!editing || _gesture == null || selectedIDs.isEmpty) return;
    final originals = _gesture!.nodes
        .where((n) => selectedIDs.contains(n.id))
        .map(
          (n) => n.kind == 'pipe' ? n.withPoints(_gesture!.pipePoints(n)) : n,
        )
        .toList();
    final left = originals.map((n) => n.rect.left).reduce(math.min);
    final top = originals.map((n) => n.rect.top).reduce(math.min);
    final right = originals.map((n) => n.rect.right).reduce(math.max);
    final bottom = originals.map((n) => n.rect.bottom).reduce(math.max);
    final target = snapPoint(Offset(left, top) + delta);
    final d = Offset(
      (target.dx - left).clamp(-left, document.width - right),
      (target.dy - top).clamp(-top, document.height - bottom),
    );
    if (d == Offset.zero) {
      document = _gesture!;
      notifyListeners();
      return;
    }
    final moved = {
      for (final n in originals)
        n.id: n.kind == 'pipe'
            ? n.moved(d).update({
                if (!selectedIDs.contains(n.startNode)) 'start_node': '',
                if (!selectedIDs.contains(n.startNode)) 'start_port': '',
                if (!selectedIDs.contains(n.endNode)) 'end_node': '',
                if (!selectedIDs.contains(n.endNode)) 'end_port': '',
              })
            : n.moved(d),
    };
    document = _gesture!.copy(
      nodes: [for (final n in _gesture!.nodes) moved[n.id] ?? n],
    );
    notifyListeners();
  }

  void layer(bool forward) {
    final n = selected;
    if (n == null) return;
    final nodes = [...document.nodes]..removeWhere((e) => e.id == n.id);
    if (forward) {
      nodes.add(n);
    } else {
      nodes.insert(0, n);
    }
    commit(document.copy(nodes: nodes));
  }

  void beginGesture() {
    _gesture = document;
  }

  void gestureUpdate(ScreenElement node) {
    if (!editing) return;
    document = document.copy(
      nodes: [for (final n in document.nodes) n.id == node.id ? node : n],
    );
    notifyListeners();
  }

  void endGesture() {
    if (_gesture != null && !identical(_gesture, document)) {
      _undo.add(_gesture!);
      if (_undo.length > 50) _undo.removeAt(0);
      _redo.clear();
    }
    _gesture = null;
    notifyListeners();
  }

  void cancelGesture() {
    if (_gesture != null) document = _gesture!;
    _gesture = null;
    notifyListeners();
  }

  void move(Offset delta) {
    if (selectedIDs.length > 1) {
      beginGesture();
      gestureMoveSelection(delta);
      endGesture();
      return;
    }
    final n = selected;
    if (n == null) return;
    final resolved = n.kind == 'pipe'
        ? n.withPoints(document.pipePoints(n))
        : n;
    final target = snapPoint(resolved.rect.topLeft + delta);
    final clamped = Offset(
      (target.dx - resolved.x).clamp(
        -resolved.x,
        document.width - resolved.rect.right,
      ),
      (target.dy - resolved.y).clamp(
        -resolved.y,
        document.height - resolved.rect.bottom,
      ),
    );
    update(resolved.moved(clamped));
  }

  void resizeCanvas(double width, double height) {
    if (document.nodes.any(
      (n) =>
          n.rect.right > width ||
          n.rect.bottom > height ||
          n.kind == 'pipe' &&
              document.pipePoints(n).any((p) => p.dx > width || p.dy > height),
    )) {
      throw const FormatException('画布尺寸不能裁切现有元素');
    }
    commit(document.copy(width: width, height: height));
  }

  (String, String, Offset)? connection(Offset position, double tolerance) {
    for (final n in document.nodes.reversed.where(
      (n) =>
          !ProcessPresentation.omitBackdrop(document, n) &&
          n.kind != 'pipe' &&
          n.kind != 'text' &&
          n.kind != 'value',
    )) {
      for (final side in document.ports(n)) {
        final port = document.port(n.id, side);
        if ((port - position).distance <= tolerance) return (n.id, side, port);
      }
    }
    (String, String, Offset)? nearest;
    var distance = tolerance;
    for (final n in document.nodes.reversed.where((n) => n.kind == 'pipe')) {
      final points = document.pipeRoute(n).points;
      final total = List.generate(
        points.length - 1,
        (i) => (points[i + 1] - points[i]).distance,
      ).fold(0.0, (a, b) => a + b);
      var travelled = 0.0;
      for (var i = 1; i < points.length; i++) {
        final a = points[i - 1], delta = points[i] - a;
        final t = delta.distanceSquared == 0
            ? 0.0
            : (((position - a).dx * delta.dx + (position - a).dy * delta.dy) /
                      delta.distanceSquared)
                  .clamp(0.0, 1.0);
        var point = a + delta * t;
        var fraction = total == 0
            ? 0.0
            : (travelled + delta.distance * t) / total;
        // Prefer an exact end over a tiny accidental branch near that end.
        if ((position - points.first).distance <= tolerance) {
          point = points.first;
          fraction = 0;
        } else if ((position - points.last).distance <= tolerance) {
          point = points.last;
          fraction = 1;
        }
        final nextDistance = (point - position).distance;
        if (nextDistance <= distance) {
          distance = nextDistance;
          nearest = (n.id, 'path:${fraction.toStringAsFixed(12)}', point);
        }
        travelled += delta.distance;
      }
    }
    return nearest;
  }

  void addPipe(
    List<Offset> points, {
    (String, String, Offset)? start,
    (String, String, Offset)? end,
    bool? orthogonal,
  }) {
    if (points.length < 2) return;
    var node = ScreenElement.create('pipe', Offset.zero).withPoints(
      points,
      changes: {
        'start_node': start?.$1 ?? '',
        'orthogonal': orthogonal ?? this.orthogonal,
        'start_port': start?.$2 ?? '',
        'end_node': end?.$1 ?? '',
        'end_port': end?.$2 ?? '',
      },
    );
    if (start != null || end != null) {
      node = node.withPoints(
        document.copy(nodes: [...document.nodes, node]).pipePoints(node),
      );
    }
    add(node);
  }

  void rename(String name) {
    if (name.trim().isNotEmpty) commit(document.copy(name: name.trim()));
  }

  void changeStyle(Json changes, {String? nodeID}) {
    final n = nodeID == null
        ? selected
        : document.nodes.where((n) => n.id == nodeID).firstOrNull;
    if (n != null) update(n.update(changes));
  }
}
