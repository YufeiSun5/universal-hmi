import 'package:flutter/material.dart';
import 'model.dart';

/// A read-only palette for the bundled heating drawing. Never saved back to
/// the source document; custom backgrounds and semantic pipe colors survive.
abstract final class ProcessPresentation {
  static const canvas = Color(0xffe9ecef);
  // Static studio lighting gives the metal equipment depth without adding
  // animation, imagery or contrast behind readings. Runtime display only.
  static const backdropDecoration = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xffd9e1e7),
        Color(0xfff0f3f5),
        Color(0xffd5dee5),
        Color(0xffbac7d1),
      ],
      stops: [0, .34, .72, 1],
    ),
  );

  static ScreenElement? backdrop(ScreenDocument doc) => doc.nodes
      .where(
        (n) =>
            n.kind == 'rect' &&
            n.x == 0 &&
            n.y == 0 &&
            n.width == doc.width &&
            n.height == doc.height,
      )
      .firstOrNull;

  static bool legacyBackdrop(ScreenDocument doc, ScreenElement n) =>
      n.id == 'monitor-backdrop' &&
      n.kind == 'rect' &&
      n.x == 0 &&
      n.y == 0 &&
      n.width == doc.width &&
      n.height == doc.height;

  static bool omitBackdrop(ScreenDocument doc, ScreenElement n) =>
      legacyBackdrop(doc, n) &&
      (doc.background != null || n.fill == const Color(0xff162f45));

  static bool legacyStyle(ScreenDocument doc) =>
      doc.background == null &&
      doc.nodes.any(
        (n) => legacyBackdrop(doc, n) && n.fill == const Color(0xff162f45),
      );

  static final _lightCache = Expando<ScreenDocument>();
  static ScreenDocument light(ScreenDocument doc) =>
      _lightCache[doc] ??= _light(doc);

  static ScreenDocument _light(ScreenDocument doc) {
    if (doc.background != null) return doc;
    final background = backdrop(doc);
    if (background?.id != 'monitor-backdrop' ||
        background?.fill != const Color(0xff162f45)) {
      return doc;
    }
    return doc.copy(
      nodes: [
        for (final n in doc.nodes)
          if (n == background)
            n.update({'color': '#e9ecef', 'fill': '#e9ecef'})
          else if (n.kind == 'text')
            n.update({
              if (n.color == const Color(0xff40baff)) 'color': '#31566d',
              if (n.color == const Color(0xffbcd0de)) 'color': '#586c79',
            })
          else if (n.kind == 'value' && n.color == const Color(0xffede94b))
            n.update({'color': '#243d4d'})
          else if (n.kind == 'rect' &&
              n.color == const Color(0xff26d6df) &&
              n.fill == const Color(0xff162f45) &&
              n.pointID.isEmpty)
            n.update({'color': '#a9b8c2', 'fill': '#f1f3f5'})
          else
            n,
      ],
    );
  }
}
