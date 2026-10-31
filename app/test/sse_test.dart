import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/sse.dart';

void main() {
  Map<String, dynamic> frame(
    int sequence, {
    bool reset = false,
    List<Map<String, dynamic>> values = const [],
    List<String> removed = const [],
    String version = 'v1',
  }) => {
    'epoch': 'connection-a',
    'sequence': sequence,
    'version': version,
    'kind': reset ? 'reset' : 'delta',
    'values': values,
    'removed': removed,
    if (reset) 'meta': {'version': version, 'sources': []},
  };
  test(
    'delta merge preserves metadata, clears bad values and removes old points',
    () {
      final merger = RuntimeDeltaMerger();
      final first = merger.accept(
        frame(
          1,
          reset: true,
          values: [
            {'point_id': 'a', 'unit': 'kPa', 'value': 10, 'quality': 'good'},
            {'point_id': 'b', 'value': 20, 'quality': 'good'},
          ],
        ),
      );
      final next = merger.accept(
        frame(
          2,
          values: [
            {'point_id': 'a', 'value': null, 'quality': 'bad'},
          ],
          removed: ['b'],
        ),
      );
      expect((next['values'] as List).single, {
        'point_id': 'a',
        'unit': 'kPa',
        'value': null,
        'quality': 'bad',
      });
      expect((first['values'] as List).length, 2);
      expect((first['values'] as List).first['value'], 10);
      final heartbeat = merger.accept(frame(3));
      expect(identical(next['values'], heartbeat['values']), true);
      final reset = merger.accept(frame(4, reset: true, version: 'v2'));
      expect(reset['values'], isEmpty);
    },
  );
  test(
    'delta without reset, skipped sequence and changed epoch fail closed',
    () {
      expect(
        () => RuntimeDeltaMerger().accept(frame(1)),
        throwsFormatException,
      );
      final merger = RuntimeDeltaMerger()..accept(frame(1, reset: true));
      expect(() => merger.accept(frame(3)), throwsFormatException);
      expect(
        () => merger.accept({...frame(2), 'epoch': 'connection-b'}),
        throwsFormatException,
      );
      expect(
        () => merger.accept(frame(2, version: 'v2')),
        throwsFormatException,
      );
      expect(
        RuntimeDeltaMerger().accept({
          ...frame(1, reset: true),
          'epoch': 'connection-b',
        })['values'],
        isEmpty,
      );
    },
  );
  test('fragmented delta SSE produces merged snapshots', () async {
    final input = [
      frame(
        1,
        reset: true,
        values: [
          {'point_id': 'a', 'value': 1},
        ],
      ),
      frame(
        2,
        values: [
          {'point_id': 'a', 'value': 2},
        ],
      ),
    ].map((f) => 'event: runtime-delta\ndata: ${jsonEncode(f)}\n\n').join();
    final output = await decodeRuntimeEvents(
      Stream.fromIterable(utf8.encode(input).map((b) => [b])),
    ).toList();
    expect((output.last['values'] as List).single['value'], 2);
  });
  test('SSE decodes fragmented unicode and separate full frames', () async {
    final bytes = utf8.encode(
      ': heartbeat\r\nevent: runtime\r\ndata: {"station":"庄河","values":[]}\r\n\r\nevent: runtime\ndata: {"values":[42]}\n\n',
    );
    final result = await decodeRuntimeEvents(
      Stream.fromIterable(bytes.map((b) => [b])),
    ).toList();
    expect(result[0]['station'], '庄河');
    expect(result[1]['values'], [42]);
  });
  test('SSE explicit revocation cannot be interpreted as live data', () async {
    await expectLater(
      decodeRuntimeEvents(
        Stream.value(utf8.encode('event: session-expired\ndata: {}\n\n')),
      ),
      emitsError(isA<RuntimeSessionExpired>()),
    );
  });
}
