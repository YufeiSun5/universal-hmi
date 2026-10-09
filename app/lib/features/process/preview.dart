import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'catalog.dart';
import 'diagram.dart';
import 'model.dart';

class ProcessEmbeddedPreview extends StatefulWidget {
  const ProcessEmbeddedPreview({
    super.key,
    required this.document,
    required this.symbols,
    required this.readings,
  });
  final ScreenDocument document;
  final Map<String, ProcessSymbol> symbols;
  final ValueListenable<ProcessReadings> readings;
  @override
  State<ProcessEmbeddedPreview> createState() => _ProcessEmbeddedPreviewState();
}

class _ProcessEmbeddedPreviewState extends State<ProcessEmbeddedPreview> {
  static const sizes = {
    '宽面板 · 960×480': Size(960, 480),
    '双栏 · 640×360': Size(640, 360),
    '窄栏 · 360×300': Size(360, 300),
    '低高度 · 640×220': Size(640, 220),
  };
  String selected = sizes.keys.first;
  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      child: SizedBox(
        width: math.min(1100, screen.width - 48),
        height: math.min(610, screen.height - 72),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Text(
                    '嵌入预览',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Semantics(
                      label: '预览容器尺寸',
                      child: DropdownButton<String>(
                        key: const Key('preview-size'),
                        value: selected,
                        isExpanded: true,
                        items: [
                          for (final label in sizes.keys)
                            DropdownMenuItem(value: label, child: Text(label)),
                        ],
                        onChanged: (value) => setState(() => selected = value!),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: const Color(0xffe8edf3),
                child: LayoutBuilder(
                  builder: (_, box) {
                    final size = sizes[selected]!;
                    final width = math.min(size.width, box.maxWidth - 16),
                        height = math.min(size.height, box.maxHeight - 16);
                    return Center(
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: ValueListenableBuilder<ProcessReadings>(
                          valueListenable: widget.readings,
                          builder: (_, data, _) => ProcessDiagram(
                            document: widget.document,
                            symbols: widget.symbols,
                            definitions: data.definitions,
                            live: data.live,
                            online: data.online,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '随容器等比显示；可放大拖动，或切换变量表。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
