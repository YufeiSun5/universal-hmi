import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import '../features/external_sites/sites.dart';
import '../shared/api.dart';
import 'external_site_view_stub.dart' as fallback;

class ExternalSiteView extends StatefulWidget {
  const ExternalSiteView({super.key, required this.site, required this.api});
  final ExternalSite site;
  final PlatformApi api;
  @override
  State<ExternalSiteView> createState() => _ExternalSiteViewState();
}

class _ExternalSiteViewState extends State<ExternalSiteView> {
  final controller = WebviewController();
  StreamSubscription<WebErrorStatus>? errors;
  bool ready = false;
  String? error;
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(initialize());
    }
  }

  Future<void> initialize() async {
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      ready = true;
      await controller.setAllowedOrigin(Uri.parse(widget.site.url).origin);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      errors = controller.onLoadError.listen((_) {
        if (mounted) setState(() => error = '外站连接失败，请稍后重试');
      });
      await controller.loadUrl(widget.site.url);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => error = '外站暂时无法打开，请检查网络和 WebView2 Runtime');
    }
  }

  @override
  void dispose() {
    unawaited(errors?.cancel());
    if (ready) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return fallback.ExternalSiteView(site: widget.site, api: widget.api);
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!),
            OutlinedButton(
              onPressed: ready
                  ? () {
                      setState(() => error = null);
                      unawaited(controller.reload());
                    }
                  : null,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!ready) return const Center(child: CircularProgressIndicator());
    return Webview(
      controller,
      permissionRequested: (_, _, _) async => WebviewPermissionDecision.deny,
    );
  }
}
