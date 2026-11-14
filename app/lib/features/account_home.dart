import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/page_access.dart';
import '../shared/mobile_client.dart';
import 'security_layout.dart';

class AccountHome extends StatefulWidget {
  const AccountHome({super.key, required this.api, this.onOpen});
  final PlatformApi api;
  final ValueChanged<String>? onOpen;
  @override
  State<AccountHome> createState() => _AccountHomeState();
}

class _AccountHomeState extends State<AccountHome> {
  PageAccess? access;
  String selected = '';
  String? error, message;
  bool busy = false;
  bool get mobile => isMobileProductClient();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = PageAccess.fromJson(
        await widget.api.request('GET', '/api/v1/page-access'),
      );
      if (mounted) {
        setState(() {
          access = data;
          selected = data.home;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await widget.api.request(
        'POST',
        '/api/v1/account/home',
        body: {'home': selected, 'revision': access!.revision},
      );
      await load();
      if (mounted) setState(() => message = '登录首页已保存，下次登录生效。一个账号共用一个首页。');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final choices =
        access?.supported(mobile).where((p) => p.configured).toList() ??
        <PageDestination>[];
    final current = access?.pages
        .where((p) => p.id == access?.home)
        .firstOrNull;
    final unavailable =
        selected.isNotEmpty && !choices.any((p) => p.id == selected);
    final fallback = access?.resolve(mobile: mobile).destination;
    return SecuritySection(
      title: '登录首页',
      description: '电脑和手机共用账号设置；当前终端不支持时临时回退，保留原首页。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const LinearProgressIndicator(),
          if (access != null) ...[
            Text(
              '当前设置：${access!.home.isEmpty ? '系统默认' : current?.label ?? homeName(access!.home)}',
            ),
            if (access!.home.isNotEmpty &&
                access!.find(access!.home, mobile, requireConfigured: true) ==
                    null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('本端将打开：${fallback?.label ?? '账号与权限说明'}。原设置不会被覆盖。'),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('account-home-$selected'),
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择登录首页'),
              items: [
                const DropdownMenuItem(value: '', child: Text('系统默认')),
                if (unavailable)
                  DropdownMenuItem(
                    value: selected,
                    enabled: false,
                    child: Text(
                      '${current?.label ?? homeName(selected)}（本端不可用，保留原设置）',
                    ),
                  ),
                for (final p in choices)
                  DropdownMenuItem(value: p.id, child: Text(p.label)),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() => selected = v ?? ''),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: busy || unavailable || selected == access!.home
                      ? null
                      : save,
                  child: const Text('保存首页'),
                ),
                if (widget.onOpen != null)
                  OutlinedButton(
                    onPressed: busy || selected != access!.home
                        ? null
                        : () => widget.onOpen!(fallback?.id ?? ''),
                    child: const Text('立即打开'),
                  ),
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('刷新设置'),
                ),
              ],
            ),
          ],
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (access == null && !busy)
            TextButton(onPressed: load, child: const Text('重试加载首页设置')),
          if (message != null) Text(message!),
        ],
      ),
    );
  }
}

String homeName(String id) =>
    const {
      'materials/catalog': '物料管理 · 品类管理',
      'materials/inbound': '物料管理 · 入库管理',
      'materials/outbound': '物料管理 · 出库管理',
      'materials/stock': '物料管理 · 库存管理',
      'materials/applications': '物料管理 · 申请与审批',
      'materials/chains': '物料管理 · 操作日志',
      'overview': '数据总览',
      'gis': 'GIS',
      'process': '工艺画面',
      'history': '历史',
      'energy': '能耗管理',
      'equipment': '设备台账',
      'alarms': '报警记录',
      'total-reports': '总统计报表',
      'workbench': '开发工作台',
      'qiwei': '七维科技',
      'boer': '沈阳波尔',
    }[id] ??
    '原首页（当前不可访问）';
