import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'runtime palette preserves source, geometry, bindings and custom colors',
    () async {
      final original = ScreenDocument.fromJson(
        jsonDecode(
          await rootBundle.loadString(
            'assets/process/templates/heating-monitor.json',
          ),
        ),
      );
      final value = original.nodes.firstWhere((n) => n.kind == 'value');
      final doc = original.copy(
        nodes: [
          for (final n in original.nodes)
            if (n == value) n.update({'point_id': 'station-a-temp'}) else n,
        ],
      );
      final before = jsonEncode(doc.toJson());
      final shown = ProcessPresentation.light(doc);
      expect(
        ProcessPresentation.backdrop(shown)!.fill,
        ProcessPresentation.canvas,
      );
      expect(jsonEncode(doc.toJson()), before);
      expect(shown.revision, doc.revision);
      for (var i = 0; i < doc.nodes.length; i++) {
        final a = {...doc.nodes[i].data}
          ..remove('color')
          ..remove('fill');
        final b = {...shown.nodes[i].data}
          ..remove('color')
          ..remove('fill');
        expect(b, a);
        if (doc.nodes[i].kind == 'pipe' || doc.nodes[i].kind == 'symbol') {
          expect(shown.nodes[i].data, doc.nodes[i].data);
        }
      }
      final custom = doc.copy(
        nodes: [
          for (final n in doc.nodes)
            if (n.id == 'monitor-backdrop')
              n.update({'fill': '#445566'})
            else
              n,
        ],
      );
      expect(identical(ProcessPresentation.light(custom), custom), isTrue);
      final warning = doc.copy(
        nodes: [
          for (final n in doc.nodes)
            if (n.id == value.id) n.update({'color': '#ff0000'}) else n,
        ],
      );
      expect(
        ProcessPresentation.light(
          warning,
        ).nodes.firstWhere((n) => n.id == value.id).color,
        const Color(0xffff0000),
      );
    },
  );
}
