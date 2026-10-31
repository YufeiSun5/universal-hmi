import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/templates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('anonymous variants are editable, connected and independent', () async {
    for (final variant in [
      ('branch-three', true, 3, true),
      ('single-three', false, 3, false),
      ('single-two', false, 2, false),
      ('single-one', false, 1, false),
      ('series-one', false, 1, true),
    ]) {
      final raw = await rootBundle.loadString(
        'assets/process/templates/heating-${variant.$1}.json',
      );
      final document = ScreenDocument.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      document.checkGeometry();
      // Compare reading frames, excluding the value inside each frame.
      final readings = document.nodes
          .where(
            (n) =>
                n.kind == 'rect' &&
                n.id.startsWith('secondary-') &&
                (n.id.endsWith('-box') || n.id.endsWith('-box-b')),
          )
          .toList();
      bool intersects(ScreenElement a, ScreenElement b) =>
          a.x < b.x + b.width &&
          b.x < a.x + a.width &&
          a.y < b.y + b.height &&
          b.y < a.y + a.height;
      for (var i = 0; i < readings.length; i++) {
        for (var j = i + 1; j < readings.length; j++) {
          expect(
            intersects(readings[i], readings[j]),
            isFalse,
            reason:
                '${variant.$1}: ${readings[i].id} overlaps ${readings[j].id}',
          );
        }
        for (final label in document.nodes.where(
          (n) => n.id == 'meter-a-label' || n.id == 'meter-b-label',
        )) {
          expect(
            intersects(readings[i], label),
            isFalse,
            reason: '${variant.$1}: ${readings[i].id} overlaps ${label.id}',
          );
        }
      }
      for (final label in document.nodes.where(
        (n) => n.id == 'meter-a-label' || n.id == 'meter-b-label',
      )) {
        for (final meter in document.nodes.where(
          (n) => n.id == 'secondary-meter' || n.id == 'secondary-meter-b',
        )) {
          expect(
            intersects(label, meter),
            isFalse,
            reason: '${variant.$1}: ${label.id} overlaps ${meter.id}',
          );
        }
      }
      if (variant.$4) {
        final groupA = readings
            .where(
              (n) =>
                  !n.id.endsWith('-b') &&
                  (n.id.contains('flow') || n.id.contains('heat')),
            )
            .toList();
        final groupB = readings.where((n) => n.id.endsWith('-b')).toList();
        final rightA = groupA
            .map((n) => n.x + n.width)
            .reduce((a, b) => a > b ? a : b);
        final leftB = groupB.map((n) => n.x).reduce((a, b) => a < b ? a : b);
        expect(leftB - rightA, greaterThanOrEqualTo(16));
      }
      expect(document.station, isEmpty);
      expect(document.nodes.every((n) => n.pointID.isEmpty), isTrue);
      if (variant.$1 == 'single-two') {
        for (final id in [
          'circulation-pump',
          'circulation-pump-2',
          'circulation-parallel-2',
          'circulation-frequency-2',
          'circulation-current-2',
        ]) {
          expect(document.nodes.where((n) => n.id == id), hasLength(1));
        }
      }
      expect(
        document.nodes.any((n) => n.id == 'secondary-branch-b'),
        variant.$2,
      );
      expect(
        document.nodes.any((n) => n.id == 'secondary-meter-b'),
        variant.$4,
      );
      expect(
        document.nodes
            .where(
              (n) =>
                  n.kind == 'value' && n.id.startsWith('circulation-frequency'),
            )
            .length,
        variant.$3,
      );
      for (final name in ['中心站', '景泰', '金岳', '帝景', '东区', '南区', '西北区']) {
        expect(raw.contains(name), isFalse);
      }
      final template = ProcessTemplates.catalog.singleWhere(
        (t) => t.id == 'heating-${variant.$1}',
      );
      final a = await template.load('A');
      final b = await template.load('B');
      expect(a.id, isNot(b.id));
      expect(a.station, 'A');
      expect(b.station, 'B');
      expect(identical(a.nodes, b.nodes), isFalse);
    }
  });
}
