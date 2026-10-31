import 'package:flutter/material.dart';

/// Native WebView integration is separate from the browser deployment.
class GisView extends StatelessWidget {
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
  Widget build(BuildContext context) => const Center(
    child: SelectableText(
      'GIS 地图已接入 Web 首页\n请在此服务的浏览器页面中打开“首页 GIS”',
      textAlign: TextAlign.center,
    ),
  );
}
