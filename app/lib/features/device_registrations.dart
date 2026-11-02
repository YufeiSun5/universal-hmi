import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import '../shared/desktop_dialog.dart';

const _devicesPath = '/api/v1/security/devices';
const _notice = '手机首次登录后自动提交申请。在这里批准一次，该设备即可登录查看；停用后立即失效。';

class DeviceRegistrationsPanel extends StatefulWidget {
  const DeviceRegistrationsPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<DeviceRegistrationsPanel> createState() =>
      _DeviceRegistrationsPanelState();
}

class _DeviceRegistrationsPanelState extends State<DeviceRegistrationsPanel> {
  List<Json> items = [], users = [];
  int revision = 0;
  bool busy = false, modal = false, closing = false, loaded = false;
  String? error, ownerError;
  bool get locked => busy || modal || closing;
  @override
  void initState() {
    super.initState();
    load();
  }

  void accept(Json snapshot) {
    revision = snapshot['revision'] as int;
    items = objects(snapshot['items']);
    loaded = true;
  }

  Future<void> load() async {
    if (locked) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final snapshot = await widget.api.request('GET', _devicesPath);
      if (!mounted) return;
      setState(() => accept(snapshot));
      try {
        final result = await widget.api.request(
          'GET',
          '/api/v1/security/users',
        );
        if (!mounted) return;
        users = objects(result['items']);
        ownerError = null;
      } catch (_) {
        users = [];
        ownerError = '账号列表不可用；不能新建登记，已有归属仅显示原账号 ID。';
      }
    } catch (_) {
      if (mounted) error = '设备登记加载失败；已有列表为上次结果，当前状态未确认。';
    }
    if (mounted) setState(() => busy = false);
  }

  void close() {
    if (locked) return;
    setState(() => closing = true);
    Navigator.pop(context);
  }

  Future<void> edit([Json? item]) async {
    if (locked ||
        !loaded ||
        error != null ||
        (item == null && ownerError != null)) {
      return;
    }
    setState(() => modal = true);
    final snapshot = await showDialog<Json>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RegistrationEditor(
        api: widget.api,
        revision: revision,
        users: users,
        item: item,
      ),
    );
    if (!mounted) return;
    setState(() {
      modal = false;
      if (snapshot != null) accept(snapshot);
    });
    if (snapshot == null) await load();
  }

  Future<void> disable(Json item) async {
    if (locked || error != null) return;
    setState(() => modal = true);
    var answered = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('停用设备登记？'),
        content: Text('${item['label']}\n停用为终态；相关证书及现有手机登录将失效。'),
        actions: [
          TextButton(
            onPressed: () {
              if (answered) return;
              answered = true;
              Navigator.pop(c, false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (answered) return;
              answered = true;
              Navigator.pop(c, true);
            },
            child: const Text('确认停用'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => modal = false);
    if (accepted != true) return;
    setState(() => busy = true);
    try {
      final snapshot = await widget.api.request(
        'POST',
        '$_devicesPath/${item['id']}/disable',
        body: {'revision': revision},
      );
      if (mounted) setState(() => accept(snapshot));
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PlatformRequestException && e.statusCode == 409
              ? '登记已被修改；请刷新并重新核对后再操作。'
              : '停用失败；请刷新核对登记状态。',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> approveLogin(Json item) async {
    if (locked || error != null) return;
    setState(() => busy = true);
    try {
      final snapshot = await widget.api.request(
        'POST',
        '$_devicesPath/${item['id']}/approve-login',
        body: {'revision': revision},
      );
      if (mounted) setState(() => accept(snapshot));
    } catch (e) {
      if (mounted) setState(() => error = '批准失败，请刷新后核对设备申请。');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> fingerprint(Json item) async {
    if (locked) return;
    setState(() => modal = true);
    var dismissed = false;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('完整公钥指纹 SHA-256'),
        content: SelectableText('${item['spki_sha256']}'),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(
                  ClipboardData(text: '${item['spki_sha256']}'),
                );
              } catch (_) {
                if (c.mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(
                    const SnackBar(content: Text('复制失败，请手动选择指纹。')),
                  );
                }
              }
            },
            child: const Text('复制指纹'),
          ),
          TextButton(
            onPressed: () {
              if (dismissed) return;
              dismissed = true;
              Navigator.pop(c);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (mounted) setState(() => modal = false);
  }

  String owner(Json item) {
    final matches = users.where((u) => u['id'] == item['owner_user_id']);
    final label = matches.isEmpty ? '未解析账号' : '${matches.first['username']}';
    final state =
        const {
          'active': '账号可用',
          'disabled': '账号停用',
          'missing': '账号不存在',
        }[item['owner_status']] ??
        '账号状态未确认';
    return '$label · ID ${item['owner_user_id']} · $state';
  }

  String state(Json item) => item['login_leaf_pem'] != null
      ? const {
              'pending': '正在审批',
              'approved': '已批准，可登录',
              'disabled': '已停用',
            }[item['state']] ??
            '未知状态'
      : const {
              'pending': '待审批',
              'approved': '登记审批通过（还需证书与入口授权）',
              'disabled': '已停用（终态）',
            }[item['state']] ??
            '未知登记状态';
  String shortFingerprint(Json item) {
    final text = item['spki_sha256']?.toString() ?? '';
    return text.length > 24
        ? '${text.substring(0, 16)}…${text.substring(text.length - 8)}'
        : text;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: Dialog(
      child: SizedBox(
        width: 880,
        height: 650,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '设备审批（仅本机）',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭设备登记',
                    onPressed: locked ? null : close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const Text(_notice),
                  const Text('请核对申请账号及设备。用户无需导出证书或填写设备码；原有手工登记仍可管理。'),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (ownerError != null) Text(ownerError!),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: locked ? null : load,
                        child: const Text('刷新登记'),
                      ),
                      FilledButton(
                        onPressed:
                            locked ||
                                !loaded ||
                                error != null ||
                                ownerError != null
                            ? null
                            : () => edit(),
                        child: const Text('新建设备登记'),
                      ),
                    ],
                  ),
                  if (busy) const LinearProgressIndicator(),
                  if (!busy && loaded && error == null && items.isEmpty)
                    const Text('暂无设备登记。'),
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${item['label']} · ${state(item)}'),
                          Text('归属：${owner(item)}'),
                          Text('到期：${item['expires_at'] ?? '尚未设置'}'),
                          if (DateTime.tryParse(
                                '${item['expires_at']}',
                              )?.isBefore(DateTime.now()) ==
                              true)
                            const Text('登记已到期（不改变审批状态记录）'),
                          Text('安装登记 ID：${item['id']}'),
                          Text('公钥指纹：${shortFingerprint(item)}'),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (item['login_leaf_pem'] != null &&
                                  item['state'] == 'pending')
                                FilledButton(
                                  onPressed: locked || error != null
                                      ? null
                                      : () => approveLogin(item),
                                  child: const Text('批准'),
                                ),
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () => fingerprint(item),
                                child: const Text('查看 / 复制完整指纹'),
                              ),
                              TextButton(
                                onPressed:
                                    locked ||
                                        error != null ||
                                        item['login_leaf_pem'] != null ||
                                        !const [
                                          'pending',
                                          'approved',
                                        ].contains(item['state'])
                                    ? null
                                    : () => edit(item),
                                child: Text(
                                  item['state'] == 'approved'
                                      ? '调整登记有效期'
                                      : '审批登记',
                                ),
                              ),
                              TextButton(
                                onPressed:
                                    locked ||
                                        error != null ||
                                        item['state'] == 'disabled'
                                    ? null
                                    : () => disable(item),
                                child: const Text('停用登记'),
                              ),
                            ],
                          ),
                          const Divider(),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RegistrationEditor extends StatefulWidget {
  const _RegistrationEditor({
    required this.api,
    required this.revision,
    required this.users,
    this.item,
  });
  final PlatformApi api;
  final int revision;
  final List<Json> users;
  final Json? item;
  @override
  State<_RegistrationEditor> createState() => _RegistrationEditorState();
}

class _RegistrationEditorState extends State<_RegistrationEditor> {
  final formScroll = ScrollController();
  final label = TextEditingController(), csr = TextEditingController();
  late final expiry = TextEditingController(
    text: DateTime.now()
        .toUtc()
        .add(const Duration(days: 3653))
        .toIso8601String(),
  );
  late int revision = widget.revision;
  late List<Json> users = widget.users;
  String? ownerID, error;
  bool busy = false,
      dirty = false,
      conflict = false,
      closing = false,
      confirming = false,
      targetValid = true;
  bool get approval => widget.item != null;
  @override
  void dispose() {
    formScroll.dispose();
    label.dispose();
    csr.dispose();
    expiry.dispose();
    super.dispose();
  }

  Future<void> cancel() async {
    if (busy || closing || confirming) return;
    if (dirty) {
      confirming = true;
      var answered = false;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('放弃未提交的登记内容？'),
          actions: [
            TextButton(
              onPressed: () {
                if (answered) return;
                answered = true;
                Navigator.pop(c, false);
              },
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () {
                if (answered) return;
                answered = true;
                Navigator.pop(c, true);
              },
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      confirming = false;
      if (accepted != true || !mounted) return;
    }
    setState(() => closing = true);
    Navigator.pop(context);
  }

  Future<void> refreshConflict() async {
    if (busy || closing || confirming) return;
    setState(() => busy = true);
    try {
      final snapshot = await widget.api.request('GET', _devicesPath);
      final accounts = await widget.api.request(
        'GET',
        '/api/v1/security/users',
      );
      if (!mounted) return;
      final current = objects(
        snapshot['items'],
      ).where((i) => i['id'] == widget.item?['id']);
      setState(() {
        revision = snapshot['revision'] as int;
        users = objects(accounts['items']);
        targetValid =
            !approval ||
            (current.isNotEmpty &&
                const ['pending', 'approved'].contains(current.first['state']));
        conflict = false;
        error = targetValid
            ? '版本已刷新，输入已保留。请重新核对账号、公钥和到期时间后提交。'
            : '此登记已不可审批，不能提交；输入保留供核对。';
      });
    } catch (_) {
      if (mounted) setState(() => error = '刷新失败，输入保留；未取得新版本，不能重试提交。');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    if (busy || closing || confirming || conflict || !targetValid) return;
    final at = DateTime.tryParse(expiry.text.trim());
    final active = users.any(
      (u) => u['id'] == ownerID && u['disabled'] != true,
    );
    if ((approval &&
            (at == null || !at.isUtc || !at.isAfter(DateTime.now()))) ||
        (!approval &&
            (!active ||
                label.text.trim().isEmpty ||
                csr.text.trim().isEmpty))) {
      setState(
        () => error = approval
            ? '请输入将来的 UTC 到期时间（RFC3339，结尾 Z）。'
            : '请选择启用账号并填写标签及已有 CSR PEM。',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final snapshot = await widget.api.request(
        'POST',
        approval ? '$_devicesPath/${widget.item!['id']}/approve' : _devicesPath,
        body: {
          'revision': revision,
          if (approval)
            'expires_at': at!.toUtc().toIso8601String()
          else ...{
            'owner_user_id': ownerID,
            'label': label.text.trim(),
            'csr_pem': csr.text,
          },
        },
      );
      if (!mounted) return;
      setState(() => closing = true);
      Navigator.pop(context, snapshot);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          conflict = e is PlatformRequestException && e.statusCode == 409;
          error = conflict
              ? '登记版本冲突，输入已保留。必须刷新版本并核对后才能重试。'
              : '提交失败，输入已保留；请核对登记内容。';
        });
      }
    }
  }

  Widget field(
    String name,
    TextEditingController controller, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key('registration-$name'),
      controller: controller,
      enabled: !busy,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 6,
      decoration: InputDecoration(labelText: name),
      onChanged: (_) => dirty = true,
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) cancel();
    },
    child: AlertDialog(
      shape: DesktopDialogStyle.shape,
      clipBehavior: Clip.antiAlias,
      backgroundColor: DesktopDialogStyle.background,
      insetPadding: DesktopDialogStyle.insetPadding,
      titlePadding: EdgeInsets.zero,
      contentPadding: DesktopDialogStyle.contentPadding,
      actionsPadding: DesktopDialogStyle.actionsPadding,
      title: DesktopDialogTitle(approval ? '审批设备登记' : '新建设备登记'),
      content: SizedBox(
        width: 580,
        child: Scrollbar(
          controller: formScroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: formScroll,
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(_notice),
                const SizedBox(height: 12),
                if (approval) ...[
                  Text('归属账号 ID：${widget.item!['owner_user_id']}'),
                  SelectableText('公钥 SHA-256：${widget.item!['spki_sha256']}'),
                  const SizedBox(height: 12),
                  const Text('默认到期为当前时间后 90 天，可编辑；审批不会签发证书或开通访问。'),
                  const SizedBox(height: 16),
                  field('UTC 到期时间', expiry),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: ownerID,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '归属启用账号'),
                    items: [
                      for (final u in users.where(
                        (u) => u['disabled'] != true || u['id'] == ownerID,
                      ))
                        DropdownMenuItem(
                          value: '${u['id']}',
                          enabled: u['disabled'] != true,
                          child: Text(
                            '${u['username']} · ${u['id']}${u['disabled'] == true ? '（已停用）' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (ownerID != null &&
                          !users.any((u) => u['id'] == ownerID))
                        DropdownMenuItem(
                          value: ownerID,
                          enabled: false,
                          child: Text('$ownerID（已不可用）'),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            ownerID = value;
                            dirty = true;
                          }),
                  ),
                  const SizedBox(height: 12),
                  field('标签', label),
                  field('已有 CSR PEM', csr, lines: 4),
                  const Text('仅粘贴公开 CSR，不要粘贴私钥；重复公钥不能另建登记。'),
                ],
                if (error != null) Text(error!),
                if (conflict)
                  TextButton(
                    onPressed: busy ? null : refreshConflict,
                    child: const Text('刷新版本并核对'),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : cancel, child: const Text('取消')),
        FilledButton(
          onPressed: busy || conflict || !targetValid ? null : save,
          child: Text(busy ? '提交中…' : '提交登记'),
        ),
      ],
    ),
  );
}
