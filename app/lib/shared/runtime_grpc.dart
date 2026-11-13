import 'dart:convert';
import 'dart:typed_data';

import 'runtimewire/runtime.pb.dart' as wire;
import 'sse.dart';

const runtimeSubscribePath = '/api/v1/hmi.runtime.v1.RuntimeService/Subscribe';
const maxRuntimeFrameBytes = 32 * 1024 * 1024;

Uint8List encodeRuntimeSubscription(
  List<String>? ids, {
  bool overview = false,
}) {
  final data = wire.SubscribeRequest(
    pointIds: overview ? null : ids,
    allAuthorized: !overview && ids == null,
    overview: overview,
  ).writeToBuffer();
  final framed = Uint8List(5 + data.length);
  ByteData.sublistView(framed).setUint32(1, data.length);
  framed.setRange(5, framed.length, data);
  return framed;
}

Object? _scalar(wire.Scalar value) => switch (value.whichKind()) {
  wire.Scalar_Kind.number => value.number,
  wire.Scalar_Kind.text => value.text,
  wire.Scalar_Kind.boolean => value.boolean,
  wire.Scalar_Kind.nullValue => null,
  wire.Scalar_Kind.notSet => throw const FormatException('实时数值缺少类型'),
};

Map<String, dynamic> runtimeFrameJson(wire.RuntimeFrame frame) => {
  'epoch': frame.epoch,
  'sequence': frame.sequence.toInt(),
  'version': frame.version,
  'kind': frame.reset ? 'reset' : 'delta',
  'values': [
    for (final v in frame.values)
      {
        'point_id': v.pointId,
        'value': _scalar(v.value),
        'raw': _scalar(v.raw),
        'quality': v.quality,
        'source_time': v.sourceTime,
        'received_time': v.receivedTime,
        if (frame.reset) ...{
          'seq': v.seq.toInt(),
          'station': v.station,
          'name': v.name,
          'unit': v.unit,
          'version': v.version,
        },
      },
  ],
  'removed': frame.removed,
  if (frame.metaJson.isNotEmpty)
    'meta': jsonDecode(utf8.decode(frame.metaJson)),
};

class RuntimeGrpcException implements Exception {
  const RuntimeGrpcException(this.code);
  final int code;
  @override
  String toString() => '实时通道中断（$code）';
}

void checkRuntimeGrpcStatus(
  String? status, {
  void Function()? onSessionExpired,
}) {
  final code = int.tryParse(status ?? '');
  if (code == 16) {
    onSessionExpired?.call();
    throw const RuntimeSessionExpired();
  }
  if (code == null) throw const FormatException('实时通道缺少结束状态');
  if (code != 0) throw RuntimeGrpcException(code);
}

/// Binary gRPC-Web framing over the application's existing trusted transport.
/// Preserve bounded memory, chunk boundaries, trailers and terminal auth status.
Stream<Map<String, dynamic>> decodeGrpcRuntimeEvents(
  Stream<List<int>> chunks, {
  void Function()? onSessionExpired,
}) async* {
  final header = Uint8List(5);
  var headerSize = 0;
  Uint8List? body;
  var bodySize = 0;
  var ended = false;
  final merger = RuntimeDeltaMerger();
  await for (final chunk in chunks) {
    var offset = 0;
    while (offset < chunk.length) {
      if (ended) throw const FormatException('实时通道结束后仍有数据');
      if (headerSize < 5) {
        final count = (5 - headerSize).clamp(0, chunk.length - offset);
        header.setRange(headerSize, headerSize + count, chunk, offset);
        headerSize += count;
        offset += count;
        if (headerSize < 5) continue;
        if (header[0] != 0 && header[0] != 128) {
          throw const FormatException('实时通道帧格式不支持');
        }
        final length = ByteData.sublistView(header).getUint32(1);
        if (length > maxRuntimeFrameBytes ||
            (header[0] == 128 && length > 8192)) {
          throw const FormatException('实时数据超过大小限制');
        }
        body = Uint8List(length);
        bodySize = 0;
      }
      final payload = body!;
      final count = (payload.length - bodySize).clamp(0, chunk.length - offset);
      payload.setRange(bodySize, bodySize + count, chunk, offset);
      bodySize += count;
      offset += count;
      if (bodySize < payload.length) continue;
      if (header[0] == 128) {
        final trailers = <String, String>{};
        for (final line in utf8.decode(payload).split('\r\n')) {
          if (line.isEmpty) continue;
          final colon = line.indexOf(':');
          if (colon < 1) throw const FormatException('实时通道结束状态格式错误');
          final name = line.substring(0, colon).toLowerCase();
          if (trailers.containsKey(name)) {
            throw const FormatException('实时通道结束状态重复');
          }
          trailers[name] = line.substring(colon + 1).trim();
        }
        ended = true;
        checkRuntimeGrpcStatus(
          trailers['grpc-status'],
          onSessionExpired: onSessionExpired,
        );
      } else {
        yield merger.accept(
          runtimeFrameJson(wire.RuntimeFrame.fromBuffer(payload)),
        );
      }
      headerSize = 0;
      body = null;
    }
  }
  if (!ended || headerSize != 0 || body != null) {
    throw const FormatException('实时通道意外中断，正在重新同步');
  }
}
