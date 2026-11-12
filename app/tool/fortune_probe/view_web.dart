import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'bridge.dart';

class ProbeView extends StatefulWidget {
  const ProbeView({super.key, required this.bridge});
  final ProbeBridge bridge;
  @override
  State<ProbeView> createState() => _ProbeViewState();
}

class _ProbeViewState extends State<ProbeView> {
  final base = Uri.parse('http://127.0.0.1:19275/');
  web.HTMLIFrameElement? frame;
  late final JSFunction listener = ((web.Event event) {
    final message = event as web.MessageEvent;
    if (message.origin != base.origin ||
        frame == null ||
        message.source != frame!.contentWindow) {
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
      frame!.title = 'FortuneSheet 编辑区';
      frame!.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%';
      frame!.src = base
          .replace(queryParameters: {'parentOrigin': Uri.base.origin})
          .toString();
    },
  );
}

Future<void> writeReport(Map<String, dynamic> report) async {
  web.document.documentElement!.setAttribute(
    'data-probe-report',
    jsonEncode(report),
  );
}
