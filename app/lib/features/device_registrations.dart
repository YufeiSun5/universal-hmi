import 'security_layout.dart';
import 'security_page.dart';
import 'package:flutter/material.dart';
import '../shared/date_time_field.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import '../shared/desktop_dialog.dart';

const _devicesPath = '/api/v1/security/devices';
const _notice =
    '安卓或已安装证书的 Windows 浏览器首次登录后自动提交申请。核对申请账号和设备标识，批准一次后可切换不同账号；权限分别校验，停用设备后全部账号立即失效。';

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
  final search = TextEditingController();
  String statusFilter = 'all', sourceFilter = 'all';
  bool busy = false, modal = false, closing = false, loaded = false;
  String? error, ownerError;
  bool get locked => busy || modal || closing;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
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
    final snapshot = await openSecurityPage<Json>(
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
    final accepted = await openSecurityPage<bool>(
      context: context,
      builder: (c) => SecurityForm(
        title: const Text('停用设备登记？'),
        content: Text('${item['label']}\n停用为终态；相关证书及现有设备登录将失效。'),
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
    await openSecurityPage<void>(
      context: context,
      builder: (c) => SecurityForm(
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
    return '$label · $state';
  }

  String state(Json item) => item['login_leaf_pem'] != null
      ? const {
              'pending': '正在审批',
              'approved': '已批准',
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

  String source(Json item) => switch (item['client_kind']) {
    'android' => '安卓 App',
    'windows_browser' => 'Windows 浏览器',
    'manual' => '手工登记',
    _ => item['login_leaf_pem'] == null ? '手工登记' : '来源未识别',
  };

  IconData sourceIcon(Json item) => switch (item['client_kind']) {
    'android' => Icons.smartphone_outlined,
    'windows_browser' => Icons.desktop_windows_outlined,
    'manual' => Icons.badge_outlined,
    _ =>
      item['login_leaf_pem'] == null
          ? Icons.badge_outlined
          : Icons.devices_other_outlined,
  };

  String account(Json item) {
    final matches = users.where((u) => u['id'] == item['owner_user_id']);
    return matches.isEmpty ? '未解析账号' : '${matches.first['username']}';
  }

  String stamp(Object? value) {
    final at = DateTime.tryParse('$value');
    if (at == null) return '未记录';
    return beijingText(
      at.toUtc().add(const Duration(hours: 8)),
      time: true,
    ).replaceFirst('T', ' ');
  }

  List<Json> get visibleItems {
    final query = search.text.trim().toLowerCase();
    final found = items.where((item) {
      final kind =
          item['client_kind'] ??
          (item['login_leaf_pem'] == null ? 'manual' : 'unknown');
      return (statusFilter == 'all' || item['state'] == statusFilter) &&
          (sourceFilter == 'all' || kind == sourceFilter) &&
          [
            account(item),
            source(item),
            item['label'],
            item['request_ip'],
            item['id'],
            item['owner_user_id'],
            item['spki_sha256'],
          ].join(' ').toLowerCase().contains(query);
    }).toList();
    found.sort((a, b) {
      final pending = (a['state'] == 'pending' ? 0 : 1).compareTo(
        b['state'] == 'pending' ? 0 : 1,
      );
      if (pending != 0) return pending;
      final time = '${b['created_at']}'.compareTo('${a['created_at']}');
      return time != 0 ? time : '${a['id']}'.compareTo('${b['id']}');
    });
    return found;
  }

  Widget directoryFilters() => LayoutBuilder(
    builder: (context, box) => Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: box.maxWidth < 600 ? box.maxWidth : 300,
          child: TextField(
            key: const Key('device-search'),
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '搜索账号、设备或 IP',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(search.clear),
                    ),
            ),
          ),
        ),
        SizedBox(
          width: 148,
          child: DropdownButtonFormField<String>(
            key: const Key('device-status-filter'),
            initialValue: statusFilter,
            decoration: const InputDecoration(labelText: '审批状态'),
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('全部状态')),
              DropdownMenuItem(value: 'pending', child: Text('待审批')),
              DropdownMenuItem(value: 'approved', child: Text('已批准')),
              DropdownMenuItem(value: 'disabled', child: Text('已停用')),
            ],
            onChanged: (v) => setState(() => statusFilter = v ?? 'all'),
          ),
        ),
        SizedBox(
          width: 172,
          child: DropdownButtonFormField<String>(
            key: const Key('device-source-filter'),
            initialValue: sourceFilter,
            decoration: const InputDecoration(labelText: '设备来源'),
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('全部来源')),
              DropdownMenuItem(value: 'android', child: Text('安卓 App')),
              DropdownMenuItem(
                value: 'windows_browser',
                child: Text('Windows 浏览器'),
              ),
              DropdownMenuItem(value: 'manual', child: Text('手工登记')),
              DropdownMenuItem(value: 'unknown', child: Text('来源未识别')),
            ],
            onChanged: (v) => setState(() => sourceFilter = v ?? 'all'),
          ),
        ),
      ],
    ),
  );

  Widget registrationCard(Json item) {
    final pending = item['state'] == 'pending';
    final disabled = item['state'] == 'disabled';
    final expired =
        DateTime.tryParse('${item['expires_at']}')?.isBefore(DateTime.now()) ==
        true;
    final color = disabled || expired
        ? const Color(0xff6c7784)
        : pending
        ? const Color(0xff986000)
        : const Color(0xff22694c);
    final fingerprintText = '${item['spki_sha256'] ?? ''}';
    final short = fingerprintText.length > 8
        ? fingerprintText.substring(0, 8)
        : fingerprintText;
    final label = '${item['label'] ?? ''}';
    return SecurityDetails(
      key: ValueKey('device-record-${item['id']}'),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xffeaf0f7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                sourceIcon(item),
                color: const Color(0xff315c88),
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account(item),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${source(item)} · 设备 $short',
                    style: const TextStyle(color: Color(0xff49627a)),
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                expired && !disabled ? '${state(item)} · 已到期' : state(item),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
            Text('首次申请：${owner(item)}'),
          ],
        ),
        if (label.isNotEmpty &&
            label != '设备登录申请' &&
            !label.startsWith('Windows 浏览器 · '))
          Text('设备名称：$label'),
        Wrap(
          spacing: 24,
          runSpacing: 8,
          children: [
            Text('申请 IP：${item['request_ip'] ?? '未记录（旧记录或手工登记）'}'),
            Text('申请时间：${stamp(item['created_at'])}'),
            Text(
              '有效期至：${item['expires_at'] == null ? '待审批设置' : stamp(item['expires_at'])}',
            ),
          ],
        ),
        ExpansionTile(
          key: PageStorageKey('device-details-${item['id']}'),
          tilePadding: EdgeInsets.zero,
          title: const Text('设备详情', style: TextStyle(fontSize: 13)),
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '安装登记 ID：${item['id']}',
              key: PageStorageKey('registration-id-${item['id']}'),
            ),
            const SizedBox(height: 8),
            SelectableText(
              '首次申请账号 ID：${item['owner_user_id']}',
              key: PageStorageKey('registration-owner-${item['id']}'),
            ),
            const SizedBox(height: 8),
            SelectableText(
              '公钥指纹：${item['spki_sha256']}',
              key: PageStorageKey('registration-fingerprint-${item['id']}'),
            ),
            const SizedBox(height: 8),
            Text('批准时间：${stamp(item['approved_at'])}'),
            if (item['disabled_at'] != null)
              Text('停用时间：${stamp(item['disabled_at'])}'),
            const SizedBox(height: 8),
            const Text(
              '时间为北京时间 UTC+8。来源类型按设备证书标识展示；IP 是首次申请时服务端收到的连接地址，可能为网关地址。设备短标识取自公钥指纹。',
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            if (item['login_leaf_pem'] != null && pending)
              FilledButton(
                onPressed: locked || error != null
                    ? null
                    : () => approveLogin(item),
                child: const Text('批准'),
              ),
            TextButton(
              onPressed: locked ? null : () => fingerprint(item),
              child: const Text('查看 / 复制完整指纹'),
            ),
            if (item['login_leaf_pem'] == null)
              TextButton(
                onPressed: locked || error != null || disabled
                    ? null
                    : () => edit(item),
                child: Text(item['state'] == 'approved' ? '调整登记有效期' : '审批登记'),
              ),
            SecurityDangerButton(
              onPressed: locked || error != null || disabled
                  ? null
                  : () => disable(item),
              child: const Text('停用登记'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: SecuritySurface(
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
                  if (!SecurityPageScope.isRoot(context))
                    IconButton(
                      tooltip: '关闭设备登记',
                      onPressed: locked ? null : close,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SecurityList(
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
                    spacing: 10,
                    runSpacing: 10,
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
                  directoryFilters(),
                  if (items.isNotEmpty)
                    Text(
                      '显示 ${visibleItems.length} / ${items.length} 台设备 · 待审批优先，按申请时间排序',
                    ),
                  if (items.isNotEmpty && visibleItems.isEmpty)
                    const Text('没有匹配的设备，请调整搜索或筛选。'),
                  for (final item in visibleItems) registrationCard(item),
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
    text: beijingIso(
      beijingText(beijingNow().add(const Duration(days: 3653)), time: true),
    ),
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
      final accepted = await openSecurityPage<bool>(
        context: context,
        builder: (c) => SecurityForm(
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
    final at = DateTime.tryParse(beijingIso(expiry.text.trim()));
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
            ? '请选择将来的到期时间（北京时间 UTC+8）。'
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
    child: controller == expiry
        ? DateTimeField(
            key: Key('registration-$name'),
            controller: controller,
            label: name,
            includeTime: true,
            isoOutput: true,
            enabled: !busy,
            onChanged: (_) => dirty = true,
          )
        : TextField(
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
    child: SecurityForm(
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
                  Text('申请账号 ID：${widget.item!['owner_user_id']}'),
                  SelectableText('公钥 SHA-256：${widget.item!['spki_sha256']}'),
                  const SizedBox(height: 12),
                  const Text('默认有效期约10年，可选择到期日期；审批与证书准入状态分别记录。'),
                  const SizedBox(height: 16),
                  field('到期时间（北京时间）', expiry),
                ] else ...[
                  DropdownButtonFormField<String>(
                    key: const Key('registration-owner'),
                    initialValue: ownerID,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '申请启用账号'),
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
