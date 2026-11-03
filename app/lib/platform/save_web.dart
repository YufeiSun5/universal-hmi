import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:web/web.dart' as web;

bool _pending = false;
Future<bool> saveFile(Uint8List bytes, String name) async {
  if (Uri.base.host == '127.0.0.1' &&
      web.window.navigator.userAgent.contains('; wv)') &&
      Uri.base.queryParameters['client'] == 'android' &&
      name.toLowerCase().endsWith('.csv')) {
    if (_pending) throw StateError('请先完成当前文件保存');
    _pending = true;
    final done = Completer<bool>();
    globalContext.setProperty(
      'hmiCsvChunk'.toJS,
      ((JSNumber start) {
        final offset = start.toDartInt;
        return base64Encode(
          Uint8List.sublistView(
            bytes,
            offset,
            math.min(offset + 49152, bytes.length),
          ),
        ).toJS;
      }).toJS,
    );
    globalContext.setProperty(
      'hmiCsvDone'.toJS,
      ((JSString result) {
        if (done.isCompleted) return;
        if (result.toDart == 'error') {
          done.completeError(StateError('未能完整保存 CSV，请检查保存位置并重试'));
        } else {
          done.complete(result.toDart == 'saved');
        }
      }).toJS,
    );
    try {
      web.window.location.assign(
        Uri(
          path: '/_hmi_native/save_csv',
          queryParameters: {'name': name, 'size': bytes.length.toString()},
        ).toString(),
      );
      return await done.future;
    } finally {
      _pending = false;
      globalContext.delete('hmiCsvChunk'.toJS);
      globalContext.delete('hmiCsvDone'.toJS);
    }
  }
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 10),
    () => web.URL.revokeObjectURL(url),
  );
  return true;
}
