import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

bool isLayoutControl(Widget w) =>
    w is TextField ||
    w is ButtonStyleButton ||
    w is IconButton ||
    w is DropdownButton ||
    w is FilterChip ||
    w is Checkbox ||
    w is Switch;

/// Opt-in development diagnostic across the whole Navigator and its overlays.
/// Debounce animated transitions and avoid scheduling any extra frames.
void enableLayoutAudit() {
  Timer? timer;
  String previous = '';
  WidgetsBinding.instance.addPersistentFrameCallback((_) {
    if (timer?.isActive == true) return;
    timer = Timer(const Duration(milliseconds: 350), () {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) return;
      final controls = <Element>[];
      void inspect(Element e) {
        if (isLayoutControl(e.widget)) {
          final box = e.findRenderObject();
          if (box is RenderBox && box.attached && box.hasSize) {
            final point = box.localToGlobal(box.size.center(Offset.zero));
            final hit = HitTestResult();
            WidgetsBinding.instance.hitTestInView(
              hit,
              point,
              View.of(e).viewId,
            );
            if (hit.path.any((entry) => entry.target == box)) controls.add(e);
          }
        }
        e.debugVisitOnstageChildren(inspect);
      }

      inspect(root);
      final report = jsonEncode(measureLayout(const [], controls));
      if (report != previous && (report != '[]' || previous.isNotEmpty)) {
        debugPrint('UI-LINT $report');
      }
      previous = report;
    });
  });
}

/// Runtime geometry checks. Only on-screen controls are measured; callers also
/// scroll each page and exercise forms, errors and expanded states.
List<Map<String, Object>> measureLayout(
  Iterable<Element> textElements,
  Iterable<Element> controlElements, {
  double minTarget = 44,
  double minGap = 8,
}) {
  final issues = <Map<String, Object>>[];
  for (final element in textElements) {
    final paragraph = element.findRenderObject();
    if (paragraph is! RenderParagraph) continue;
    final text = paragraph.text.toPlainText();
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(text)) continue;
    final style = paragraph.text.style;
    if (style?.fontFamily != 'HmiCJK' &&
        !(style?.fontFamilyFallback?.contains('HmiCJK') ?? false)) {
      issues.add({
        'rule': 'bundled-cjk-font',
        'control': text.length > 24 ? text.substring(0, 24) : text,
        'font': style?.fontFamily ?? 'unset',
      });
    }
  }
  final controls = <({Element element, Rect rect, String label})>[];
  for (final element in controlElements) {
    final box = element.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    // A scrolling control can be partly clipped above a fixed footer. Its
    // off-screen bounds are not an overlap; inspect it once fully scrolled in.
    var clipped = false;
    element.visitAncestorElements((parent) {
      final render = parent.findRenderObject();
      if (render is RenderAbstractViewport && render is RenderBox) {
        final viewportBox = render as RenderBox;
        if (!viewportBox.hasSize) return true;
        final viewport =
            viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
        if (!viewport.inflate(.5).contains(rect.topLeft) ||
            !viewport.inflate(.5).contains(rect.bottomRight)) {
          clipped = true;
        }
      }
      return !clipped;
    });
    if (clipped) continue;
    final widget = element.widget;
    final label = widget is TextField
        ? widget.decoration?.labelText ?? 'TextField'
        : widget is IconButton
        ? widget.tooltip ?? 'IconButton'
        : element.toStringShort();
    controls.add((element: element, rect: rect, label: label));
    // The entire labeled tile toggles its value. Measure the tile for touch
    // size and the visual controls above for spacing.
    final tile = widget is Switch
        ? element.findAncestorWidgetOfExactType<SwitchListTile>()
        : widget is Checkbox
        ? element.findAncestorWidgetOfExactType<CheckboxListTile>()
        : null;
    RenderObject? targetBox;
    if (tile != null) {
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget != tile) return true;
        targetBox = ancestor.findRenderObject();
        return false;
      });
    }
    final hitBox = targetBox;
    final targetSize = hitBox is RenderBox && hitBox.hasSize
        ? hitBox.size
        : rect.size;
    if (targetSize.height + .5 < minTarget ||
        targetSize.width + .5 < minTarget) {
      issues.add({
        'rule': 'target-size',
        'control': label,
        'rect': rect.toString(),
        'minimum': minTarget,
      });
    }
  }
  bool ancestor(Element a, Element b) {
    var found = false;
    b.visitAncestorElements((parent) {
      if (parent == a) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  for (var i = 0; i < controls.length; i++) {
    for (var j = i + 1; j < controls.length; j++) {
      final a = controls[i], b = controls[j];
      if (ancestor(a.element, b.element) || ancestor(b.element, a.element)) {
        continue;
      }
      final x =
          math.min(a.rect.right, b.rect.right) -
          math.max(a.rect.left, b.rect.left);
      final y =
          math.min(a.rect.bottom, b.rect.bottom) -
          math.max(a.rect.top, b.rect.top);
      if (x > .5 && y > .5) {
        issues.add({
          'rule': 'control-overlap',
          'controls': '${a.label} / ${b.label}',
          'overlap': '${x.toStringAsFixed(1)} × ${y.toStringAsFixed(1)}',
        });
      } else if ((x > .5 && y <= .5 && -y < minGap - .5) ||
          (y > .5 && x <= .5 && -x < minGap - .5)) {
        issues.add({
          'rule': 'control-gap',
          'controls': '${a.label} / ${b.label}',
          'minimum': minGap,
        });
      }
    }
  }
  return issues;
}
