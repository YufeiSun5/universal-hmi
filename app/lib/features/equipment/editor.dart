import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/desktop_dialog.dart';
import 'model.dart';
import 'signals.dart';

class EquipmentEditor extends StatefulWidget {
  const EquipmentEditor({
    super.key,
    required this.api,
    required this.stations,
    this.device,
    this.initialStation = '',
    this.initialSite = '',
  });
  final PlatformApi api;
  final List<String> stations;
  final Json? device;
  final String initialStation, initialSite;
  @override
  State<EquipmentEditor> createState() => _EquipmentEditorState();
}

class _EquipmentEditorState extends State<EquipmentEditor> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields = {
    for (final k in [
      'name',
      'code',
      'site',
      'model',
      'manufacturer',
      'serial',
      'installed',
      'location',
      'notes',
    ])
      k: TextEditingController(
        text:
            widget.device?[k]?.toString() ??
            (k == 'site' ? widget.initialSite : ''),
      ),
  };
  late String station =
      widget.device?['station'] as String? ?? widget.initialStation;
  late String category = widget.device?['category'] as String? ?? '水泵';
  late String photoFit =
      const {'contain', 'cover', 'fill'}.contains(widget.device?['photo_fit'])
      ? widget.device!['photo_fit'] as String
      : 'contain';
  late List<List<TextEditingController>> properties =
      objects(widget.device?['properties'])
          .map(
            (p) => [
              for (final k in ['name', 'value', 'unit'])
                TextEditingController(text: value(p, k)),
            ],
          )
          .toList();
  bool busy = false, dirty = false, closing = false;
  String? error;
  late Json signals = Map<String, dynamic>.from(
    widget.device?['signals'] as Map? ?? {},
  );
  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    for (final row in properties) {
      for (final c in row) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void changed() {
    if (!dirty) setState(() => dirty = true);
  }

  Future<void> cancel() async {
    if (busy) return;
    if (dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = <String, dynamic>{
        if (widget.device != null) ...widget.device!,
        for (final e in fields.entries) e.key: e.value.text.trim(),
        'station': station,
        'category': category,
        'photo_fit': photoFit,
        'signals': signals,
        'properties': [
          for (final row in properties)
            {
              'name': row[0].text.trim(),
              'value': row[1].text.trim(),
              'unit': row[2].text.trim(),
            },
        ],
      };
      final result = await widget.api.request(
        'POST',
        '/api/v1/equipment',
        body: d,
      );
      if (!mounted) return;
      setState(() => closing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, result);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Widget input(
    String key,
    String label, {
    bool required = false,
    String? hint,
    int lines = 1,
  }) => TextFormField(
    key: Key('equipment-field-$key'),
    controller: fields[key],
    enabled: !busy,
    maxLines: lines,
    decoration: InputDecoration(
      labelText: '$label${required ? ' *' : ''}',
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    onChanged: (_) => changed(),
    validator: (v) =>
        required && (v == null || v.trim().isEmpty) ? '请填写$label' : null,
  );
  Widget title(String text, String number) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 18),
    child: Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ledgerAccent.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            number,
            style: const TextStyle(color: ledgerAccent, fontSize: 11),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) cancel();
    },
    child: Dialog(
      shape: DesktopDialogStyle.shape,
      clipBehavior: Clip.antiAlias,
      backgroundColor: DesktopDialogStyle.background,
      insetPadding: DesktopDialogStyle.insetPadding,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 820),
        child: Column(
          children: [
            Container(
              color: DesktopDialogStyle.header,
              padding: DesktopDialogStyle.titlePadding,
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, color: ledgerAccent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.device == null ? '新增设备档案' : '编辑设备档案',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '登记基础信息与技术属性，保存后可上传设备图片',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff8294a0),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : cancel,
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: DesktopDialogStyle.line),
            Expanded(
              child: SingleChildScrollView(
                padding: DesktopDialogStyle.contentPadding,
                child: Form(
                  key: form,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final width = box.maxWidth < 520
                          ? box.maxWidth
                          : (box.maxWidth - 16) / 2;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          title('归属与基本信息', '01'),
                          Wrap(
                            spacing: 16,
                            runSpacing: 18,
                            children: [
                              SizedBox(
                                width: width,
                                child: DropdownButtonFormField<String>(
                                  key: const Key('equipment-station'),
                                  initialValue: station.isEmpty
                                      ? null
                                      : station,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '所属大站区 *',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: widget.stations
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: s,
                                          child: Text(
                                            s,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  validator: (v) =>
                                      v == null || v.isEmpty ? '请选择站区' : null,
                                  onChanged: busy
                                      ? null
                                      : (v) {
                                          setState(() => station = v ?? '');
                                          changed();
                                        },
                                ),
                              ),
                              SizedBox(
                                width: width,
                                child: input(
                                  'site',
                                  '所属小站',
                                  hint: '留空表示站区直属设备',
                                ),
                              ),
                              SizedBox(
                                width: width,
                                child: input('name', '设备名称', required: true),
                              ),
                              SizedBox(
                                width: width,
                                child: input(
                                  'code',
                                  '设备编号',
                                  required: true,
                                  hint: '工程内唯一，例如 P-001',
                                ),
                              ),
                              SizedBox(
                                width: width,
                                child: DropdownButtonFormField<String>(
                                  initialValue: category,
                                  decoration: const InputDecoration(
                                    labelText: '设备类别',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: {...equipmentKinds, category}
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: s,
                                          child: Text(s),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: busy
                                      ? null
                                      : (v) {
                                          setState(() => category = v!);
                                          changed();
                                        },
                                ),
                              ),
                              SizedBox(
                                width: width,
                                child: input('manufacturer', '生产厂家'),
                              ),
                              SizedBox(
                                width: width,
                                child: input('model', '型号规格'),
                              ),
                              SizedBox(
                                width: width,
                                child: input('serial', '出厂编号'),
                              ),
                              SizedBox(
                                width: width,
                                child: input(
                                  'installed',
                                  '投运日期',
                                  hint: 'YYYY-MM-DD',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          DropdownButtonFormField<String>(
                            key: const Key('equipment-photo-fit'),
                            initialValue: photoFit,
                            decoration: const InputDecoration(
                              labelText: '图片显示方式',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'contain',
                                child: Text('完整显示'),
                              ),
                              DropdownMenuItem(
                                value: 'cover',
                                child: Text('裁切填满'),
                              ),
                              DropdownMenuItem(
                                value: 'fill',
                                child: Text('拉伸填满'),
                              ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) {
                                    setState(() => photoFit = v!);
                                    changed();
                                  },
                          ),
                          const SizedBox(height: 18),
                          input('location', '安装位置', hint: '例如：一层泵房 / 2号机组'),
                          const SizedBox(height: 20),
                          EquipmentSignalsEditor(
                            api: widget.api,
                            initial: signals,
                            enabled: !busy,
                            onChanged: (next) {
                              signals = next;
                              changed();
                            },
                          ),
                          const SizedBox(height: 20),
                          title('技术属性', '02'),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              '按设备需要填写，例如功率、流量、扬程、换热面积。',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xff8294a0),
                              ),
                            ),
                          ),
                          for (int i = 0; i < properties.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (int j = 0; j < 3; j++) ...[
                                    if (j > 0) const SizedBox(width: 8),
                                    Expanded(
                                      flex: j == 2 ? 1 : 2,
                                      child: TextFormField(
                                        controller: properties[i][j],
                                        enabled: !busy,
                                        onChanged: (_) => changed(),
                                        decoration: InputDecoration(
                                          labelText: [
                                            '属性名称',
                                            '数值 / 内容',
                                            '单位',
                                          ][j],
                                          border: const OutlineInputBorder(),
                                          isDense: true,
                                        ),
                                        validator: j == 0
                                            ? (v) =>
                                                  v == null || v.trim().isEmpty
                                                  ? '请填名称'
                                                  : null
                                            : null,
                                      ),
                                    ),
                                  ],
                                  IconButton(
                                    tooltip: '移除此属性',
                                    onPressed: busy
                                        ? null
                                        : () {
                                            setState(() {
                                              final row = properties.removeAt(
                                                i,
                                              );
                                              for (final c in row) {
                                                c.dispose();
                                              }
                                              dirty = true;
                                            });
                                          },
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                      size: 19,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const Key('equipment-add-property'),
                              onPressed: busy || properties.length >= 32
                                  ? null
                                  : () => setState(() {
                                      properties.add(
                                        List.generate(
                                          3,
                                          (_) => TextEditingController(),
                                        ),
                                      );
                                      dirty = true;
                                    }),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加属性'),
                            ),
                          ),
                          const SizedBox(height: 20),
                          title('备注说明', '03'),
                          input('notes', '备注', lines: 3),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              ),
            const Divider(height: 1, color: DesktopDialogStyle.line),
            Padding(
              padding: DesktopDialogStyle.actionsPadding,
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(
                      onPressed: busy ? null : cancel,
                      child: const Text('取消'),
                    ),
                    FilledButton.icon(
                      key: const Key('equipment-save'),
                      onPressed: busy ? null : save,
                      icon: const Icon(Icons.check, size: 17),
                      label: Text(busy ? '正在保存…' : '保存档案'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
