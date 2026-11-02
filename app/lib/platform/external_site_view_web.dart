import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../features/external_sites/sites.dart';
import '../shared/api.dart';

class ExternalSiteView extends StatefulWidget {
  const ExternalSiteView({super.key, required this.site, required this.api});
  final ExternalSite site;
  final PlatformApi api;
  @override
  State<ExternalSiteView> createState() => _ExternalSiteViewState();
}

class _ExternalSiteViewState extends State<ExternalSiteView> {
  late Future<Json> configuration = widget.api.request(
    'GET',
    '/api/v1/external-sites',
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: configuration,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: OutlinedButton(
            onPressed: () => setState(
              () => configuration = widget.api.request(
                'GET',
                '/api/v1/external-sites',
              ),
            ),
            child: const Text('外站加载失败，重试'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final url = snapshot.data![widget.site.id]?.toString() ?? widget.site.url;
      final parsed = Uri.tryParse(url);
      final target = parsed == null
          ? null
          : Uri.parse(web.document.baseURI).resolveUri(parsed);
      final sandboxed = snapshot.data!['sandboxed'] == true;
      if (target == null ||
          !const ['https', 'http'].contains(target.scheme) ||
          !target.hasAuthority) {
        return const Center(child: Text('外站地址不可用'));
      }
      final blocked =
          web.window.location.protocol == 'https:' && target.scheme == 'http';
      return Column(
        children: [
          Container(
            height: 36,
            color: const Color(0xffe9ecef),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.site.name} · 独立登录',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final a = web.HTMLAnchorElement()
                      ..href = widget.site.url
                      ..target = '_blank'
                      ..rel = 'noopener noreferrer';
                    a.click();
                  },
                  child: const Text('在独立窗口打开'),
                ),
              ],
            ),
          ),
          Expanded(
            child: blocked
                ? const Center(child: Text('外站接入尚未就绪，请刷新后重试。'))
                : HtmlElementView.fromTagName(
                    tagName: 'iframe',
                    onElementCreated: (element) {
                      final frame = element as web.HTMLIFrameElement;
                      frame.title = widget.site.name;
                      frame.style
                        ..border = '0'
                        ..width = '100%'
                        ..height = '100%';
                      frame.referrerPolicy = 'no-referrer';
                      frame.setAttribute(
                        'sandbox',
                        sandboxed
                            ? 'allow-scripts allow-forms allow-modals'
                            : 'allow-scripts allow-same-origin allow-forms allow-modals',
                      );
                      if (sandboxed) {
                        // An opaque wrapper keeps the CHIPS ancestor partition
                        // consistent for initial navigation and later XHR.
                        final safe = target
                            .toString()
                            .replaceAll('&', '&amp;')
                            .replaceAll('"', '&quot;')
                            .replaceAll('<', '&lt;');
                        frame.setAttribute(
                          'srcdoc',
                          '<!doctype html><style>html,body,iframe{margin:0;width:100%;height:100%;border:0;overflow:hidden}</style><iframe sandbox="allow-scripts allow-forms allow-modals" referrerpolicy="no-referrer" src="$safe"></iframe>',
                        );
                      } else {
                        frame.src = url;
                      }
                    },
                  ),
          ),
        ],
      );
    },
  );
}
