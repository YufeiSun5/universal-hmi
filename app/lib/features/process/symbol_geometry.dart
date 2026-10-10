import 'dart:math' as math;
import 'dart:ui';
import 'symbol_sizes.dart';

const plateHeatExchangerPorts = [
  'left_top',
  'left_bottom',
  'right_top',
  'right_bottom',
];
const equipmentPorts = ['left', 'right', 'top', 'bottom'];

// Authored drawing coordinates: these contacts meet the painted device itself.
// Imported symbols without reviewed contacts use their SVG viewport edges.
const _contacts = <String, Map<String, Offset>>{
  'example_plate_hx': {
    'left_top': Offset(0, 32.5),
    'left_bottom': Offset(0, 125.5),
    'right_top': Offset(110, 32.5),
    'right_bottom': Offset(110, 125.5),
  },
  'example_pump': {
    'left': Offset(6.5, 32),
    'right': Offset(61.5, 30),
    'top': Offset(40, 8.5),
    'bottom': Offset(40, 51.5),
  },
  'example_tank': {
    'left': Offset(10, 64),
    'right': Offset(90, 64),
    'top': Offset(50, 5),
    'bottom': Offset(50, 105),
  },
  'example_valve': {
    'left': Offset(10, 37),
    'right': Offset(70, 37),
    'top': Offset(40, 4),
    'bottom': Offset(40, 49.5),
  },
};

int symbolQuarterTurns(int rotation) => (rotation ~/ 90) % 4;

Offset _rotate(Offset point, int turns) => switch (turns) {
  1 => Offset(1 - point.dy, point.dx),
  2 => Offset(1 - point.dx, 1 - point.dy),
  3 => Offset(point.dy, 1 - point.dx),
  _ => point,
};

/// Same contained, centered SVG viewport for drawing and all connection points.
Rect symbolContentRect(String symbol, Rect bounds, int rotation) {
  var size = processSymbolSizes[symbol];
  if (size == null) return bounds;
  if (symbolQuarterTurns(rotation).isOdd) size = Size(size.height, size.width);
  final scale = math.min(
    bounds.width / size.width,
    bounds.height / size.height,
  );
  return Rect.fromCenter(
    center: bounds.center,
    width: size.width * scale,
    height: size.height * scale,
  );
}

Offset symbolPortPoint(String symbol, Rect bounds, int rotation, String side) {
  final size = processSymbolSizes[symbol];
  final contact = _contacts[symbol]?[side];
  final normalized = contact != null && size != null
      ? Offset(contact.dx / size.width, contact.dy / size.height)
      : switch (side) {
          'left' => const Offset(0, .5),
          'right' => const Offset(1, .5),
          'top' => const Offset(.5, 0),
          'bottom' => const Offset(.5, 1),
          'left_top' => const Offset(0, .2),
          'left_bottom' => const Offset(0, .8),
          'right_top' => const Offset(1, .2),
          'right_bottom' => const Offset(1, .8),
          _ => const Offset(.5, .5),
        };
  final point = _rotate(normalized, symbolQuarterTurns(rotation));
  final rect = symbolContentRect(symbol, bounds, rotation);
  return Offset(
    rect.left + point.dx * rect.width,
    rect.top + point.dy * rect.height,
  );
}
