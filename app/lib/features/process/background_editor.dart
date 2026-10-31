import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../platform/process_files.dart';
import 'model.dart';
import 'presentation.dart';
import 'scene.dart';
import 'image_validation.dart';

/// Validate before changing the dialog draft or the document's embedded assets.
Future<EmbeddedImage> backgroundImage(ProcessFile file) async {
  final bytes = file.bytes;
  final header = processImageHeader(bytes);
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    decoded = (await codec.getNextFrame()).image;
    if (decoded.width < 1 ||
        decoded.height < 1 ||
        decoded.width > 8192 ||
        decoded.height > 8192 ||
        decoded.width * decoded.height > 16000000) {
      throw const FormatException('图片单边不超过8192像素，总像素不超过1600万');
    }
    return EmbeddedImage(file.name, header.mime, base64Encode(bytes));
  } finally {
    decoded?.dispose();
    codec?.dispose();
  }
}

Future<ScreenDocument?> editProcessBackground(
  BuildContext context,
  ScreenDocument source, {
  Future<ProcessFile?> Function()? pickImage,
}) {
  if (source.linked) return Future.value();
  return showDialog<ScreenDocument>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BackgroundEditor(
      source: source,
      pickImage: pickImage ?? () => pickProcessFile(image: true),
    ),
  );
}

class _BackgroundEditor extends StatefulWidget {
  const _BackgroundEditor({required this.source, required this.pickImage});
  final ScreenDocument source;
  final Future<ProcessFile?> Function() pickImage;
  @override
  State<_BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<_BackgroundEditor> {
  late String type = widget.source.background?['type'] as String? ?? 'legacy';
  late String image = widget.source.background?['image'] as String? ?? '';
  late String fit = widget.source.background?['fit'] as String? ?? 'cover';
  late double opacity =
      (widget.source.background?['opacity'] as num?)?.toDouble() ?? 1;
  late double angle =
      (widget.source.background?['angle'] as num?)?.toDouble() ?? 90;
  late final color = TextEditingController(
    text: widget.source.background?['color'] as String? ?? '#d9e1e7',
  );
  late final end = TextEditingController(
    text: widget.source.background?['end_color'] as String? ?? '#bac7d1',
  );
  late Map<String, EmbeddedImage> assets = {...widget.source.assets};
  bool loading = false;
  String? failure;
  @override
  void dispose() {
    color.dispose();
    end.dispose();
    super.dispose();
  }

  ScreenDocument draft() {
    final used = widget.source.nodes
        .where((n) => n.kind == 'image')
        .map((n) => n.image)
        .toSet();
    if (type == 'image' && image.isNotEmpty) used.add(image);
    final retainedAssets = {
      for (final entry in assets.entries)
        if (used.contains(entry.key)) entry.key: entry.value,
    };
    if (type == 'legacy') {
      return widget.source.copy(clearBackground: true, assets: retainedAssets);
    }
    parseColor(color.text);
    if (type == 'linear') parseColor(end.text);
    return widget.source.copy(
      assets: retainedAssets,
      background: {
        'type': type,
        'color': color.text,
        'opacity': opacity,
        if (type == 'linear') ...{'end_color': end.text, 'angle': angle},
        if (type == 'image') ...{'image': image, 'fit': fit},
      },
    );
  }

  void removeImage() {
    final previous = image;
    if (!widget.source.nodes.any(
      (n) => n.kind == 'image' && n.image == previous,
    )) {
      assets.remove(previous);
    }
    image = '';
    type = 'solid';
  }

  Future<void> upload() async {
    if (loading) return;
    setState(() {
      loading = true;
      failure = null;
    });
    try {
      final file = await widget.pickImage();
      if (file == null) return;
      final asset = await backgroundImage(file);
      if (!mounted) return;
      final nextAssets = {...assets};
      if (!widget.source.nodes.any(
        (n) => n.kind == 'image' && n.image == image,
      )) {
        nextAssets.remove(image);
      }
      final id = screenIdentity();
      nextAssets[id] = asset;
      if (nextAssets.length > 64 ||
          utf8
                  .encode(
                    jsonEncode(widget.source.copy(assets: nextAssets).toJson()),
                  )
                  .length >
              8 * 1024 * 1024) {
        throw const FormatException('画面图片数量/文件总量超出限制');
      }
      setState(() {
        assets = nextAssets;
        image = id;
        type = 'image';
      });
    } catch (e) {
      if (mounted) setState(() => failure = '背景图片读取失败：$e；原背景保持');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void apply() {
    try {
      final next = draft();
      next.checkGeometry();
      if (utf8.encode(jsonEncode(next.toJson())).length > 8 * 1024 * 1024) {
        throw const FormatException('画面文件总量超出8 MiB限制');
      }
      Navigator.pop(context, next);
    } catch (e) {
      setState(() => failure = '背景设置无效：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    ScreenDocument preview;
    try {
      preview = draft();
    } catch (_) {
      preview = widget.source;
    }
    return PopScope(
      canPop: !loading,
      child: AlertDialog(
        title: const Text('画面背景'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 120,
                  child: ProcessBackground(document: preview),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('background-type'),
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '背景类型'),
                  items: [
                    DropdownMenuItem(
                      value: 'legacy',
                      child: Text(
                        ProcessPresentation.legacyStyle(widget.source)
                            ? '默认金属渐变（原画面）'
                            : '沿用原画面背景',
                      ),
                    ),
                    const DropdownMenuItem(value: 'solid', child: Text('纯色')),
                    const DropdownMenuItem(
                      value: 'linear',
                      child: Text('线性渐变'),
                    ),
                    const DropdownMenuItem(value: 'image', child: Text('图片')),
                  ],
                  onChanged: loading
                      ? null
                      : (v) => setState(() {
                          type = v!;
                          failure = null;
                        }),
                ),
                if (type == 'legacy')
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('保留现有背景和默认金属光照。选择其他类型后可自定义颜色、图片及透明度。'),
                  ),
                if (type != 'legacy') ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('background-color'),
                    controller: color,
                    enabled: !loading,
                    decoration: const InputDecoration(
                      labelText: '底色 / 起始色（#RRGGBB）',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (type == 'linear') ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('background-end-color'),
                      controller: end,
                      enabled: !loading,
                      decoration: const InputDecoration(
                        labelText: '结束色（#RRGGBB）',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    Text('渐变方向 ${angle.round()}°（0°向右，90°向下）'),
                    Slider(
                      key: const Key('background-angle'),
                      value: angle,
                      min: 0,
                      max: 360,
                      divisions: 24,
                      onChanged: loading
                          ? null
                          : (v) => setState(() => angle = v),
                    ),
                  ],
                  if (type == 'image') ...[
                    const SizedBox(height: 12),
                    Text(
                      image.isEmpty ? '尚未上传图片' : assets[image]?.name ?? '图片缺失',
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          key: const Key('background-upload'),
                          onPressed: loading ? null : upload,
                          icon: const Icon(Icons.upload_file),
                          label: Text(image.isEmpty ? '上传图片' : '替换图片'),
                        ),
                        if (image.isNotEmpty)
                          TextButton(
                            key: const Key('background-remove-image'),
                            onPressed: loading
                                ? null
                                : () => setState(removeImage),
                            child: const Text('移除图片'),
                          ),
                      ],
                    ),
                    DropdownButtonFormField<String>(
                      key: const Key('background-fit'),
                      initialValue: fit,
                      decoration: const InputDecoration(labelText: '图片适配'),
                      items: const [
                        DropdownMenuItem(value: 'cover', child: Text('铺满并裁切')),
                        DropdownMenuItem(value: 'contain', child: Text('完整显示')),
                        DropdownMenuItem(value: 'fill', child: Text('拉伸铺满')),
                      ],
                      onChanged: loading
                          ? null
                          : (v) => setState(() => fit = v!),
                    ),
                    const Text(
                      'PNG / JPEG · 单张2 MiB · 单边8192像素 · 总像素1600万',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                  Text('背景不透明度 ${(opacity * 100).round()}%'),
                  Slider(
                    key: const Key('background-opacity'),
                    value: opacity,
                    onChanged: loading
                        ? null
                        : (v) => setState(() => opacity = v),
                  ),
                  const Text(
                    '透明区域使用白色底板；节点颜色和透明度保持。',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
                if (failure != null)
                  Text(
                    failure!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (loading) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: loading ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('background-apply'),
            onPressed: loading ? null : apply,
            child: const Text('应用到草稿'),
          ),
        ],
      ),
    );
  }
}
