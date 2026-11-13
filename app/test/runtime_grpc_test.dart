import 'dart:convert';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/runtime_grpc.dart';
import 'package:universal_hmi/shared/runtimewire/runtime.pb.dart' as wire;
import 'package:universal_hmi/shared/sse.dart';

List<int> framed(List<int> body, [int flags = 0]) {
  final result = Uint8List(body.length + 5);
  result[0] = flags;
  ByteData.sublistView(result).setUint32(1, body.length);
  result.setRange(5, result.length, body);
  return result;
}

List<int> end([int status = 0]) =>
    framed(utf8.encode('grpc-status: $status\r\n'), 128);
wire.RuntimeFrame frame({
  bool reset = true,
  int sequence = 1,
  double value = 0,
}) => wire.RuntimeFrame(
  epoch: 'fixture',
  sequence: Int64(sequence),
  version: 'v1',
  reset: reset,
  metaJson: reset ? utf8.encode('{"version":"v1"}') : null,
  values: [
    wire.RuntimeValue(
      pointId: 'a',
      name: '温度',
      unit: '℃',
      value: wire.Scalar(number: value),
      raw: wire.Scalar(nullValue: true),
      quality: 'good',
    ),
  ],
);
void main() {
  test(
    'binary framing handles every byte split, typed zero/null and delta metadata',
    () async {
      final bytes = [
        ...framed(frame().writeToBuffer()),
        ...framed(
          frame(reset: false, sequence: 2, value: 21.5).writeToBuffer(),
        ),
        ...end(),
      ];
      final events = await decodeGrpcRuntimeEvents(
        Stream.fromIterable(bytes.map((b) => [b])),
      ).toList();
      expect(events.length, 2);
      expect(events[0]['values'][0]['value'], 0);
      expect(events[0]['values'][0]['raw'], isNull);
      expect(events[1]['values'][0]['value'], 21.5);
      expect(events[1]['values'][0]['name'], '温度');
    },
  );
  test(
    'truncated, oversized, invalid flags, missing status, gaps and trailing bytes fail closed',
    () async {
      final first = framed(frame().writeToBuffer());
      for (final bytes in <List<int>>[
        first.sublist(0, first.length - 1),
        first,
        [0, 255, 255, 255, 255],
        [1, 0, 0, 0, 0],
        [...first, ...framed(utf8.encode('grpc-message: missing\r\n'), 128)],
        [
          ...first,
          ...framed(frame(reset: false, sequence: 3).writeToBuffer()),
          ...end(),
        ],
        [...first, ...end(), 0],
      ]) {
        await expectLater(
          decodeGrpcRuntimeEvents(Stream.value(bytes)).drain<void>(),
          throwsFormatException,
        );
      }
    },
  );
  test('unauthenticated trailers retire session before throwing', () async {
    var expired = false;
    await expectLater(
      decodeGrpcRuntimeEvents(
        Stream.value(end(16)),
        onSessionExpired: () => expired = true,
      ).drain<void>(),
      throwsA(isA<RuntimeSessionExpired>()),
    );
    expect(expired, true);
  });
  test('subscription distinguishes all, empty and overview scopes', () {
    wire.SubscribeRequest decode(List<String>? ids, {bool overview = false}) =>
        wire.SubscribeRequest.fromBuffer(
          encodeRuntimeSubscription(ids, overview: overview).sublist(5),
        );
    expect(decode(null).allAuthorized, true);
    expect(decode([]).allAuthorized, false);
    expect(decode(['a']).pointIds, ['a']);
    expect(decode(['a'], overview: true).pointIds, isEmpty);
    expect(decode(null, overview: true).overview, true);
  });
  for (final grpc in [false, true]) {
    test(
      'API negotiates ${grpc ? 'gRPC-Web' : 'legacy SSE'} and preserves auth',
      () async {
        final paths = <String>[];
        final client = PlatformClient(
          Uri.parse('https://fixture.invalid'),
          client: MockClient(
            (r) async => http.Response(
              jsonEncode(
                r.url.path == '/health'
                    ? {
                        'status': 'ok',
                        if (grpc) 'runtime_transport': 'grpc-web-v1',
                      }
                    : {
                        'enabled': true,
                        'authenticated': true,
                        'csrf_token': 'csrf',
                        'bearer_token': 'fixture-token',
                        'token_type': 'Bearer',
                        'expires_at': DateTime.now()
                            .add(const Duration(hours: 1))
                            .toIso8601String(),
                      },
              ),
              200,
            ),
          ),
          streamClientFactory: () => MockClient.streaming((r, body) async {
            paths.add(r.url.path);
            expect(r.headers['Authorization'], 'Bearer fixture-token');
            if (grpc) {
              expect(r.method, 'POST');
              expect(r.headers['Content-Type'], 'application/grpc-web+proto');
              expect(r.headers['X-CSRF-Token'], 'csrf');
              final request = wire.SubscribeRequest.fromBuffer(
                (await body.toBytes()).sublist(5),
              );
              expect(request.pointIds, ['a']);
            } else {
              expect(r.method, 'GET');
              expect(r.url.queryParameters['ids'], 'a');
            }
            return http.StreamedResponse(
              Stream.value(
                grpc
                    ? [...framed(frame().writeToBuffer()), ...end()]
                    : utf8.encode('event: runtime\ndata: {"values":[]}\n\n'),
              ),
              200,
              headers: {
                'content-type': grpc
                    ? 'application/grpc-web+proto'
                    : 'text/event-stream',
              },
            );
          }),
        );
        addTearDown(client.close);
        await client.login('viewer', 'fixture');
        final data = await client.runtimeSelectedEvents(['a']).toList();
        expect(data.length, 1);
        expect(paths, [grpc ? runtimeSubscribePath : '/api/v1/runtime/events']);
      },
    );
  }
  test('new server RPC failure never falls back to SSE', () async {
    var calls = 0;
    final client = PlatformClient(
      Uri.parse('https://fixture.invalid'),
      client: MockClient(
        (r) async => http.Response('{"runtime_transport":"grpc-web-v1"}', 200),
      ),
      streamClientFactory: () => MockClient.streaming((r, b) async {
        calls++;
        expect(r.url.path, runtimeSubscribePath);
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 403);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.runtimeSelectedEvents([]).drain<void>(),
      throwsA(isA<PlatformRequestException>()),
    );
    expect(calls, 1);
  });
}
