import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import '../features/total_reports/bridge.dart';
import 'backend_endpoint.dart';
import 'gis_proxy_native.dart';
import 'total_report_view_stub.dart' as fallback;

class TotalReportView extends StatefulWidget {
  const TotalReportView({super.key, required this.bridge});
  final TotalReportBridge bridge;
  @override
  State<TotalReportView> createState() => _TotalReportViewState();
}

class _TotalReportViewState extends State<TotalReportView> {
  final controller = WebviewController();
  StreamSubscription<dynamic>? messages;
  StreamSubscription<WebErrorStatus>? loadErrors;
  Future<void> Function(String)? sender;
  GisResourceProxy? proxy;
  bool initialized = false;
  String? error;
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) unawaited(initialize());
  }

  Future<void> initialize() async {
    try {
      final endpoint = backendApiUri();
      Uri base = endpoint.resolve('total-reports/');
      if (selectedRemoteBackendUri != null) {
        proxy = await GisResourceProxy.start(
          endpoint,
          resourceDirectory: 'total-reports',
        );
        base = proxy!.base;
      }
      await controller.initialize();
      initialized = true;
      if (!mounted) {
        await controller.dispose();
        await proxy?.close();
        return;
      }
      messages = controller.webMessage.listen(widget.bridge.receive);
      loadErrors = controller.onLoadError.listen((_) {
        widget.bridge.receive({
          'channel': TotalReportBridge.channel,
          'type': 'viewError',
        });
      });
      // Use WebView2's native message channel. Injected window.postMessage
      // depends on the execution world's source/origin and script completion.
      sender = controller.postWebMessage;
      widget.bridge.send = sender;
      await controller.setCacheDisabled(true);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      final url = base
          .replace(
            queryParameters: {'development': '${widget.bridge.development}'},
          )
          .toString();
      await controller.setAllowedNavigation(url);
      await controller.loadUrl(url);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    messages?.cancel();
    loadErrors?.cancel();
    if (identical(widget.bridge.send, sender)) widget.bridge.send = null;
    if (initialized) controller.dispose();
    proxy?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !Platform.isWindows
      ? fallback.TotalReportView(bridge: widget.bridge)
      : error != null
      ? Center(child: Text(error!))
      : initialized
      ? Webview(controller)
      : const Center(child: CircularProgressIndicator());
}
