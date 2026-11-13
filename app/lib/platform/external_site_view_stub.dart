import 'package:flutter/material.dart';
import '../features/external_sites/sites.dart';
import '../shared/api.dart';

class ExternalSiteView extends StatelessWidget {
  const ExternalSiteView({super.key, required this.site, required this.api});
  final ExternalSite site;
  final PlatformApi api;
  @override
  Widget build(BuildContext context) =>
      Center(child: Text('${site.name} · 外站画面'));
}
