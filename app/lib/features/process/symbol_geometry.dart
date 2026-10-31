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
  'monitor_relief': {'bottom': Offset(480, 1470), 'right': Offset(860, 1095)},
  'monitor_tank_v2': {'left': Offset(24, 394), 'right': Offset(1420, 865)},
  'monitor_temperature': {'bottom': Offset(463, 1498)},
  'monitor_pressure_v2': {'bottom': Offset(400, 1450)},
  'monitor_hx_v2': {
    'left_top': Offset(55, 224),
    'right_top': Offset(969, 224),
    'left_bottom': Offset(55, 1224),
    'right_bottom': Offset(969, 1224),
  },
  'monitor_pump': {'left': Offset(232, 1015), 'right': Offset(1020, 1015)},
  'monitor_valve': {'left': Offset(155, 947), 'right': Offset(1104, 947)},
  'monitor_flow_meter': {'left': Offset(32, 950), 'right': Offset(1184, 950)},
  'monitor_pressure': {'bottom': Offset(430, 1450)},
  // Reviewed on the original 1024 x 1536 alpha PNG. Contacts are nozzle faces,
  // not the transparent outer image bounds; fitting/rotation share this map.
  'monitor_real_hx': {
    'left_top': Offset(120, 288),
    'left_bottom': Offset(120, 1184),
    'right_top': Offset(904, 288),
    'right_bottom': Offset(904, 1184),
  },
  'monitor_plate_hx': {
    'left_top': Offset(0, 32.5),
    'left_bottom': Offset(0, 125.5),
    'right_top': Offset(110, 32.5),
    'right_bottom': Offset(110, 125.5),
  },
  'monitor_tank': {
    'left': Offset(0, 35),
    'right': Offset(120, 60),
    'top': Offset(60, 2),
    'bottom': Offset(60, 88),
  },
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
