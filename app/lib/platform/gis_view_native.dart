import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'gis_view_stub.dart' as fallback;
import 'backend_endpoint.dart';
import 'gis_proxy_native.dart';
import 'transport.dart';

/// Windows presentation adapter. Only the packaged GIS exchanges display data;
/// credentials and all business writes remain in the Flutter API client.
class GisView extends StatefulWidget {
  const GisView({
    super.key,
    this.title = '首页 GIS',
    this.station = '',
    this.editable = false,
    this.interactive = true,
    this.readings = const {},
    this.onEditStation,
    this.onOpenStation,
    this.config,
    this.onChanged,
    this.onLoaded,
  });
  final String title, station;
  final bool editable, interactive;
  final Map<String, dynamic> readings;
  final ValueChanged<String>? onEditStation, onOpenStation;
  final Map<String, dynamic>? config;
  final ValueChanged<Map<String, dynamic>>? onChanged, onLoaded;

  @override
  State<GisView> createState() => _GisViewState();
}

class _GisViewState extends State<GisView> {
  final controller = WebviewController();
  StreamSubscription<dynamic>? messages;
  StreamSubscription<String>? navigation;
  bool initialized = false, mapReady = false;
  String? error;
  late Uri base;
  GisResourceProxy? proxy;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) initialize();
  }

  Future<void> initialize() async {
    try {
      final endpoint = backendApiUri();
      if (selectedRemoteBackendUri != null) {
        proxy = await GisResourceProxy.start(endpoint);
        base = proxy!.base;
      } else {
        base = endpoint.resolve('gis/');
      }
      final client = newTransport();
      final response = await client
          .get(base.resolve('imagery/manifest.json'))
          .timeout(const Duration(seconds: 12));
      client.close();
      if (response.statusCode != 200 || jsonDecode(response.body) is! Map) {
        throw const FormatException('GIS 资源包不可用');
      }
      if (!mounted) return;
      await controller.initialize();
      initialized = true;
      if (!mounted) {
        await controller.dispose();
        return;
      }
      messages = controller.webMessage.listen(receive, onError: fail);
      navigation = controller.url.listen((value) {
        final target = Uri.tryParse(value);
        if (target == null ||
            !target.hasAuthority ||
            target.origin != base.origin ||
            !target.path.startsWith(base.path)) {
          unawaited(controller.stop());
          fail(StateError('地图阻止了外部导航'));
        }
      });
      // Offline resources can change while the loopback origin remains fixed.
      // Never combine cached scripts from an older installed package.
      await controller.setCacheDisabled(true);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.setAllowedNavigation(
        base.resolve('map.html').toString(),
      );
      await controller.addScriptToExecuteOnDocumentCreated('''
        if (location.origin === ${jsonEncode(base.origin)} &&
            location.pathname === ${jsonEncode(base.resolve('map.html').path)}) {
          window.addEventListener('message', event => {
            if (event.source !== window || event.origin !== location.origin) return;
            try {
              const data = JSON.parse(event.data);
              if (['gis-ready', 'gis-edit-station', 'gis-open-station', 'gis-stations-loaded',
                   'gis-stations-changed'].includes(data.type)) {
                window.chrome.webview.postMessage(data);
              }
            } catch (_) {}
          });
        }
      ''');
      await controller.loadUrl(
        base
            .resolve('map.html')
            .replace(
              queryParameters: {
                'embed': '1',
                'shell': '1',
                'autoplay': '1',
                'v': 'bindings-2',
              },
            )
            .toString(),
      );
      if (mounted) setState(() {});
    } catch (e) {
      fail(e);
    }
  }

  void fail(Object e) {
    if (mounted) setState(() => error = e.toString());
  }

  void receive(dynamic message) {
    if (!mounted || message is! Map) return;
    if (message['type'] == 'gis-ready') {
      mapReady = true;
      sendConfig();
      sendReadings();
    }
    if (message['type'] == 'gis-stations-loaded' && message['config'] is Map) {
      widget.onLoaded?.call(
        Map<String, dynamic>.from(message['config'] as Map),
      );
    }
    if (!widget.editable &&
        widget.interactive &&
        message['type'] == 'gis-open-station' &&
        message['id'] is String) {
      widget.onOpenStation?.call(message['id'] as String);
    }
    if (!widget.editable || !widget.interactive) return;
    if (message['type'] == 'gis-edit-station' && message['id'] is String) {
      widget.onEditStation?.call(message['id'] as String);
    }
    if (message['type'] == 'gis-stations-changed' && message['config'] is Map) {
      widget.onChanged?.call(
        Map<String, dynamic>.from(message['config'] as Map),
      );
    }
  }

  Future<void> send(Map<String, dynamic> data) async {
    if (!mapReady || !mounted) return;
    try {
      await controller.executeScript(
        'window.postMessage(${jsonEncode(jsonEncode(data))}, ${jsonEncode(base.origin)});',
      );
    } catch (e) {
      fail(e);
    }
  }

  void sendConfig() => unawaited(
    send({
      'type': 'gis-config',
      'editable': widget.editable,
      'config': widget.config,
    }),
  );
  void sendReadings() =>
      unawaited(send({'type': 'gis-readings', 'readings': widget.readings}));

  @override
  void didUpdateWidget(covariant GisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.config) != jsonEncode(widget.config) ||
        oldWidget.editable != widget.editable) {
      sendConfig();
    }
    if (jsonEncode(oldWidget.readings) != jsonEncode(widget.readings)) {
      sendReadings();
    }
  }

  @override
  void dispose() {
    messages?.cancel();
    navigation?.cancel();
    if (proxy != null) unawaited(proxy!.close());
    if (initialized) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const fallback.GisView();
    if (error != null) {
      return Center(
        child: SelectableText(
          '地图加载失败，请确认 GIS 资源与 Microsoft Edge WebView2 Runtime 已安装。\n$error',
          textAlign: TextAlign.center,
        ),
      );
    }
    if (!initialized) return const Center(child: CircularProgressIndicator());
    return AbsorbPointer(
      absorbing: !widget.interactive,
      child: Webview(
        controller,
        permissionRequested: (_, _, _) async => WebviewPermissionDecision.deny,
      ),
    );
  }
}
