import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

class ProcessController extends ChangeNotifier {
  ProcessController(this.document);
  ScreenDocument document;
  ScreenDocument? _saved;
  String selectedID = '';
  bool grid = true, snap = true, orthogonal = true, editing = true;
  final _undo = <ScreenDocument>[], _redo = <ScreenDocument>[];
  ScreenDocument? _gesture;
  ScreenElement? _clipboard;
  EmbeddedImage? _clipboardAsset;
  ScreenElement? get selected =>
      document.nodes.where((n) => n.id == selectedID).firstOrNull;
  bool get dirty =>
      _saved == null ||
      document.name != _saved!.name ||
      document.station != _saved!.station ||
      document.width != _saved!.width ||
      document.height != _saved!.height ||
      !listEquals(document.nodes, _saved!.nodes) ||
      !mapEquals(document.assets, _saved!.assets);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void open(ScreenDocument next, {bool saved = true}) {
    document = next;
    _saved = saved ? next : null;
    selectedID = '';
    _undo.clear();
    _redo.clear();
    _gesture = null;
    _clipboard = null;
    _clipboardAsset = null;
    notifyListeners();
  }

  void saved(int revision, {ScreenDocument? snapshot}) {
    if (snapshot != null && document.id != snapshot.id) return;
    document = document.copy(revision: revision);
    _saved = snapshot?.copy(revision: revision) ?? document;
    notifyListeners();
  }

  void select(String id) {
    selectedID = id;
    notifyListeners();
  }

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
    notifyListeners();
  }

  void redo() {
    if (!editing || !canRedo) return;
    _undo.add(document);
    document = _redo.removeLast().copy(revision: document.revision);
    selectedID = '';
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
    selectedID = node.id;
    notifyListeners();
  }

  Offset snapPoint(Offset p) => Offset(
    (snap ? (p.dx / 10).round() * 10.0 : p.dx).clamp(0, document.width),
    (snap ? (p.dy / 10).round() * 10.0 : p.dy).clamp(0, document.height),
  );
  void removeSelected() {
    if (!editing) return;
    final removed = selected;
    if (removed == null) return;
    final nodes = <ScreenElement>[];
    for (final n in document.nodes) {
      if (n.id == removed.id) continue;
      nodes.add(
        n.kind == 'pipe'
            ? n.withPoints(
                document.pipePoints(n),
                changes: {
                  if (n.startNode == removed.id) 'start_node': '',
                  if (n.startNode == removed.id) 'start_port': '',
                  if (n.endNode == removed.id) 'end_node': '',
                  if (n.endNode == removed.id) 'end_port': '',
                },
              )
            : n,
      );
    }
    final used = nodes
        .where((n) => n.kind == 'image')
        .map((n) => n.image)
        .toSet();
    commit(
      document.copy(
        nodes: nodes,
        assets: Map.fromEntries(
          document.assets.entries.where((a) => used.contains(a.key)),
        ),
      ),
    );
    selectedID = '';
    notifyListeners();
  }

  void copy() {
    _clipboard = selected;
    _clipboardAsset = document.assets[_clipboard?.image];
  }

  void paste() {
    final n = _clipboard;
    if (n == null) return;
    // Image clipboard cannot outlive its document's embedded asset.
    if (n.kind == 'image' && _clipboardAsset == null) return;
    final shift = Offset(
      math.min(20, document.width - n.rect.right),
      math.min(20, document.height - n.rect.bottom),
    );
    add(
      n.moved(shift).update({'id': screenIdentity()}),
      assets: n.kind == 'image'
          ? {...document.assets, n.image: _clipboardAsset!}
          : null,
    );
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

  void move(Offset delta) {
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
      (n) => n.kind != 'pipe' && n.kind != 'text' && n.kind != 'value',
    )) {
      for (final side in document.ports(n)) {
        final port = document.port(n.id, side);
        if ((port - position).distance <= tolerance) return (n.id, side, port);
      }
    }
    return null;
  }

  void addPipe(
    List<Offset> points, {
    (String, String, Offset)? start,
    (String, String, Offset)? end,
  }) {
    if (points.length < 2) return;
    var node = ScreenElement.create('pipe', Offset.zero).withPoints(
      points,
      changes: {
        'start_node': start?.$1 ?? '',
        'orthogonal': orthogonal,
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

  void changeStyle(Json changes) {
    final n = selected;
    if (n != null) update(n.update(changes));
  }
}
