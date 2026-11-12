import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../features/total_reports/bridge.dart';

class TotalReportView extends StatefulWidget {
  const TotalReportView({super.key, required this.bridge});
  final TotalReportBridge bridge;
  @override
  State<TotalReportView> createState() => _TotalReportViewState();
}

class _TotalReportViewState extends State<TotalReportView> {
  final base = Uri.base.resolve('total-reports/');
  web.HTMLIFrameElement? frame;
  late final JSFunction listener = ((web.Event event) {
    final message = event as web.MessageEvent;
    if (message.origin != base.origin ||
        frame == null ||
        message.source != frame!.contentWindow ||
        !message.data.isA<JSString>()) {
      return;
    }
    widget.bridge.receive((message.data as JSString).toDart);
  }).toJS;
  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', listener);
    widget.bridge.send = (message) async {
      frame?.contentWindow?.postMessage(message.toJS, base.origin.toJS);
    };
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', listener);
    widget.bridge.send = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: (element) {
      frame = element as web.HTMLIFrameElement;
      frame!.title = '总统计报表';
      frame!.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%';
      frame!.src = base
          .replace(
            queryParameters: {
              'parentOrigin': Uri.base.origin,
              'development': '${widget.bridge.development}',
            },
          )
          .toString();
    },
  );
}
