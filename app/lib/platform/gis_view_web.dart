import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// The frame only renders packaged public imagery. It receives no session token
/// or business API access from the shell. Base URI also supports the /kp/ entry.
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
  late final Uri base = Uri.parse(web.document.baseURI).resolve('gis/');
  late Future<void> ready = checkResources();
  web.HTMLIFrameElement? frame;
  late final JSFunction listener = ((web.Event event) {
    final message = event as web.MessageEvent;
    if (message.origin != base.origin ||
        frame == null ||
        message.source != frame!.contentWindow) {
      return;
    }
    try {
      final data =
          jsonDecode((message.data as JSString).toDart) as Map<String, dynamic>;
      if (!widget.editable &&
          widget.interactive &&
          data['type'] == 'gis-open-station' &&
          data['id'] is String) {
        widget.onOpenStation?.call(data['id'] as String);
      }
      if (data['type'] == 'gis-ready') {
        sendConfig();
        sendReadings();
      }
      if (widget.editable &&
          widget.interactive &&
          data['type'] == 'gis-edit-station' &&
          data['id'] is String) {
        widget.onEditStation?.call(data['id'] as String);
      }
      if (data['type'] == 'gis-stations-loaded' && data['config'] is Map) {
        widget.onLoaded?.call(Map<String, dynamic>.from(data['config'] as Map));
      }
      if (widget.editable &&
          data['type'] == 'gis-stations-changed' &&
          data['config'] is Map) {
        widget.onChanged?.call(
          Map<String, dynamic>.from(data['config'] as Map),
        );
      }
    } catch (_) {
      /* Ignore messages outside the GIS presentation contract. */
    }
  }).toJS;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', listener);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', listener);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    frame?.style.pointerEvents = widget.interactive ? 'auto' : 'none';
    if (jsonEncode(oldWidget.readings) != jsonEncode(widget.readings)) {
      sendReadings();
    }
    if (jsonEncode(oldWidget.config) != jsonEncode(widget.config) ||
        oldWidget.editable != widget.editable) {
      sendConfig();
    }
  }

  void sendConfig() => frame?.contentWindow?.postMessage(
    jsonEncode({
      'type': 'gis-config',
      'editable': widget.editable,
      'config': widget.config,
    }).toJS,
    base.origin.toJS,
  );

  void sendReadings() => frame?.contentWindow?.postMessage(
    jsonEncode({'type': 'gis-readings', 'readings': widget.readings}).toJS,
    base.origin.toJS,
  );

  Future<void> checkResources() async {
    final response = await http
        .get(base.resolve('imagery/manifest.json'))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 || jsonDecode(response.body) is! Map) {
      throw const FormatException('GIS resources unavailable');
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('地图资源暂不可用，请检查本服务的 GIS 资源包'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => setState(() => ready = checkResources()),
                child: const Text('重试'),
              ),
            ],
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      return HtmlElementView.fromTagName(
        tagName: 'iframe',
        onElementCreated: (element) {
          final frame = element as web.HTMLIFrameElement;
          this.frame = frame;
          frame.title =
              '${widget.station.isEmpty ? '公共画面' : widget.station} / ${widget.title}';
          frame.style
            ..pointerEvents = widget.interactive ? 'auto' : 'none'
            ..border = '0'
            ..width = '100%'
            ..height = '100%';
          frame.allowFullscreen = true;
          frame.referrerPolicy = 'no-referrer';
          frame.src = base
              .resolve('map.html')
              .replace(
                queryParameters: {
                  'embed': '1',
                  'shell': '1',
                  'autoplay': '1',
                  'v': 'bindings-2',
                },
              )
              .toString();
        },
      );
    },
  );
}
