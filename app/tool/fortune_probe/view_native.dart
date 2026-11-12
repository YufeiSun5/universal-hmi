import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'bridge.dart';

class ProbeView extends StatefulWidget {
  const ProbeView({super.key, required this.bridge});
  final ProbeBridge bridge;
  @override
  State<ProbeView> createState() => _ProbeViewState();
}

class _ProbeViewState extends State<ProbeView> {
  final controller = WebviewController();
  StreamSubscription<dynamic>? messages;
  bool ready = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  Future<void> initialize() async {
    try {
      if (!Platform.isWindows) throw UnsupportedError('Windows only');
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      messages = controller.webMessage.listen(widget.bridge.receive);
      widget.bridge.send = (message) => controller.executeScript(
        'window.postMessage(${jsonEncode(message)}, "http://127.0.0.1:19275");',
      );
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.setAllowedNavigation('http://127.0.0.1:19275/');
      await controller.loadUrl('http://127.0.0.1:19275/');
      if (mounted) setState(() => ready = true);
    } catch (e) {
      await writeReport({'passed': false, 'error': e.toString()});
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  void dispose() {
    messages?.cancel();
    widget.bridge.send = null;
    if (ready) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => error != null
      ? Center(child: Text(error!))
      : ready
      ? Webview(controller)
      : const Center(child: CircularProgressIndicator());
}

Future<void> writeReport(Map<String, dynamic> report) async {
  const path = String.fromEnvironment('PROBE_REPORT');
  if (path.isNotEmpty) {
    await File(path).writeAsString(jsonEncode(report), flush: true);
  }
}
