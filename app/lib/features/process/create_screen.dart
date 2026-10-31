import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'diagram.dart';
import 'model.dart';
import 'templates.dart';

Future<Json?> addScreen(
  BuildContext context,
  PlatformApi api,
  String station,
) => showDialog<Json>(
  context: context,
  builder: (_) => _CreateScreen(api: api, station: station),
);

class _CreateScreen extends StatefulWidget {
  const _CreateScreen({required this.api, required this.station});
  final PlatformApi api;
  final String station;
  @override
  State<_CreateScreen> createState() => _CreateScreenState();
}

class _TemplateChoice {
  const _TemplateChoice(this.id, this.name, this.description, {this.builtin});
  final String id, name, description;
  final ProcessTemplate? builtin;
  bool get shared => builtin == null;
}

class _CreateScreenState extends State<_CreateScreen> {
  final name = TextEditingController(), search = TextEditingController();
  List<_TemplateChoice> publicTemplates = [];
  late String group = widget.station.isEmpty ? 'builtin' : 'shared';
  String kind = 'process', autoName = '';
  String? failure, catalogFailure, previewFailure;
  _TemplateChoice? selected;
  ScreenDocument? preview;
  bool loading = false, saving = false, previewLoading = false;
  int previewGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.station.isNotEmpty) load();
  }

  @override
  void dispose() {
    name.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      catalogFailure = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/screens',
        query: {'station': ''},
      );
      if (!mounted) return;
      setState(() {
        publicTemplates = objects(data['items'])
            .where((s) => s['station'] == '' && s['kind'] != 'gis')
            .map(
              (s) => _TemplateChoice(
                s['id'] as String,
                s['name'] as String,
                '公共布局同步更新，本站单独绑定变量。',
              ),
            )
            .toList();
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          catalogFailure = '$e';
        });
      }
    }
  }

  Future<ScreenDocument> read(_TemplateChoice choice) async => choice.shared
      ? ScreenDocument.fromJson(
          await widget.api.request('GET', '/api/v1/screens/${choice.id}'),
        )
      : choice.builtin!.load(widget.station);

  Future<void> select(_TemplateChoice choice) async {
    final generation = ++previewGeneration;
    setState(() {
      selected = choice;
      preview = null;
      previewFailure = null;
      previewLoading = true;
      failure = null;
      if (name.text.trim().isEmpty || name.text == autoName) {
        name.text = choice.name;
      }
      autoName = choice.name;
    });
    try {
      final document = await read(choice);
      if (mounted && generation == previewGeneration) {
        setState(() {
          preview = document;
          previewLoading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == previewGeneration) {
        setState(() {
          previewFailure = '$e';
          previewLoading = false;
        });
      }
    }
  }

  Future<void> create() async {
    if (kind == 'process' && selected == null || name.text.trim().isEmpty) {
      setState(
        () => failure = kind == 'process' && selected == null
            ? '请选择工艺图模板'
            : '请输入画面名称',
      );
      return;
    }
    setState(() {
      saving = true;
      failure = null;
    });
    try {
      ScreenDocument next;
      if (kind == 'gis') {
        next = ScreenDocument(
          id: screenIdentity(),
          name: '',
          station: '',
          kind: 'gis',
        );
      } else {
        final choice = selected!;
        final template = await read(choice);
        next = template.instantiate(widget.station, suffix: '');
        if (choice.shared) {
          next = next.copy(
            templateID: template.id,
            templateRevision: template.revision,
          );
        }
      }
      final saved = await widget.api.request(
        'PUT',
        '/api/v1/screens/${next.id}',
        body: next.copy(name: name.text.trim()).toJson(),
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          failure = '$e';
        });
      }
    }
  }

  Widget picker() {
    final query = search.text.trim().toLowerCase();
    final choices = group == 'shared'
        ? publicTemplates
        : [
            for (final t in ProcessTemplates.catalog)
              _TemplateChoice(t.id, t.name, t.description, builtin: t),
          ];
    final visible = choices
        .where(
          (t) => '${t.name} ${t.description}'.toLowerCase().contains(query),
        )
        .toList();
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('template-search'),
          controller: search,
          enabled: !saving,
          decoration: InputDecoration(
            hintText: '搜索工艺图模板',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    onPressed: saving ? null : () => setState(search.clear),
                    icon: const Icon(Icons.close),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          '共 ${visible.length} 个模板',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: loading && group == 'shared'
              ? const Center(child: CircularProgressIndicator())
              : catalogFailure != null && group == 'shared'
              ? SingleChildScrollView(
                  child: Column(
                    children: [
                      Text('公共画面读取失败：$catalogFailure'),
                      TextButton(
                        onPressed: saving ? null : load,
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                )
              : visible.isEmpty
              ? Center(
                  child: Text(
                    query.isNotEmpty ? '没有匹配的模板，请调整搜索。' : '暂无公共工艺画面，可先选择内置模板。',
                  ),
                )
              : ListView.builder(
                  key: const Key('template-list'),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final t = visible[i];
                    final active =
                        selected?.id == t.id && selected?.shared == t.shared;
                    return ListTile(
                      key: Key(
                        'template-${t.shared ? 'shared' : 'builtin'}-${t.id}',
                      ),
                      selected: active,
                      selectedTileColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      leading: Icon(
                        active
                            ? Icons.check_circle
                            : Icons.account_tree_outlined,
                      ),
                      title: Text(
                        t.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: saving ? null : () => select(t),
                    );
                  },
                ),
        ),
      ],
    );
    final image = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: previewLoading
          ? const Center(child: CircularProgressIndicator())
          : previewFailure != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('预览读取失败：$previewFailure'),
                    TextButton(
                      onPressed: saving ? null : () => select(selected!),
                      child: const Text('重试预览'),
                    ),
                  ],
                ),
              ),
            )
          : preview == null
          ? const Center(child: Text('选择模板后预览'))
          : preview!.nodes.isEmpty
          ? const Center(child: Text('空白画布'))
          : ProcessDiagram(
              key: ValueKey('${selected!.shared}-${selected!.id}'),
              document: preview!,
              definitions: const {},
              live: const {},
              online: false,
              showControls: false,
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('工艺图模板', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (widget.station.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final entry in {'shared': '公共画面', 'builtin': '内置模板'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: group == entry.key,
                  onSelected: saving
                      ? null
                      : (_) => setState(() {
                          group = entry.key;
                          search.clear();
                        }),
                ),
            ],
          ),
        const SizedBox(height: 8),
        MediaQuery.sizeOf(context).width >= 748
            ? SizedBox(
                height: 280,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: list),
                    const SizedBox(width: 12),
                    Expanded(child: image),
                  ],
                ),
              )
            : Column(
                children: [
                  SizedBox(height: 240, child: list),
                  const SizedBox(height: 8),
                  SizedBox(height: 160, width: double.infinity, child: image),
                ],
              ),
        const SizedBox(height: 8),
        Text(
          selected == null
              ? '请选择一个模板，也可以选择空白工艺画面。'
              : '已选：${selected!.name} · ${selected!.shared ? '公共布局同步，本站独立绑定' : '创建独立画面，可自由编辑'}',
          key: const Key('selected-template'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.station.isEmpty ? '新建公共画面' : '为 ${widget.station} 添加画面'),
    content: SizedBox(
      width: 820,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('screen-kind'),
            initialValue: kind,
            decoration: const InputDecoration(labelText: '画面类型'),
            items: [
              const DropdownMenuItem(value: 'process', child: Text('工艺图')),
              if (widget.station.isEmpty)
                const DropdownMenuItem(value: 'gis', child: Text('GIS 地图')),
            ],
            onChanged: saving
                ? null
                : (value) => setState(() {
                    kind = value!;
                    failure = null;
                  }),
          ),
          const SizedBox(height: 16),
          if (widget.station.isNotEmpty)
            const Text('GIS 是工程级公共驾驶舱，请在“公共画面”中创建。'),
          if (kind == 'gis') const Text('工程级公共驾驶舱，汇总展示多个站点，不归属单个站点。'),
          if (kind == 'process') picker(),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new-screen-name'),
            controller: name,
            enabled: !saving,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '画面名称'),
            onSubmitted: (_) {
              if (!saving) create();
            },
          ),
          if (failure != null)
            Text(
              failure!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : create,
        child: Text(saving ? '正在添加…' : '添加并打开'),
      ),
    ],
  );
}
