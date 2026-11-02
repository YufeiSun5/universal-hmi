import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runtime geometry checks. Only on-screen controls are measured; callers also
/// scroll each page and exercise forms, errors and expanded states.
List<Map<String, Object>> lintUI(
  WidgetTester tester, {
  double minTarget = 44,
  double minGap = 8,
}) {
  final issues = <Map<String, Object>>[];
  final controls = <({Element element, Rect rect, String label})>[];
  final finder = find
      .byWidgetPredicate(
        (w) => w is TextField || w is ButtonStyleButton || w is IconButton,
      )
      .hitTestable();
  for (final element in finder.evaluate()) {
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
    if (rect.height + .5 < minTarget || rect.width + .5 < minTarget) {
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

void expectCleanUI(WidgetTester tester, String page) {
  final exception = tester.takeException();
  expect(exception, isNull, reason: '$page: layout exception');
  final issues = lintUI(tester);
  expect(issues, isEmpty, reason: jsonEncode({'page': page, 'issues': issues}));
}
