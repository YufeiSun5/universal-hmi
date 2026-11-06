import 'package:flutter/material.dart';
import '../shared/desktop_sidebar.dart';

/// Account and security navigation; permission decisions stay with the caller
/// and the existing authenticated backend APIs.
class SecurityNavigation extends StatelessWidget {
  const SecurityNavigation({
    super.key,
    required this.username,
    required this.onRecords,
    this.onAccount,
    this.onLogout,
    this.loggingOut = false,
    this.onUsers,
    this.onRoles,
    this.onSessions,
    this.onWhitelist,
    this.onDevices,
    this.onCertificates,
    this.onBans,
    this.onNetwork,
    this.onKP,
    this.selectedSection,
  });

  final String username;
  final VoidCallback onRecords;
  final VoidCallback? onAccount, onLogout, onUsers, onRoles, onSessions;
  final VoidCallback? onWhitelist, onDevices, onCertificates, onBans;
  final bool loggingOut;
  final VoidCallback? onNetwork;
  final VoidCallback? onKP;
  final int? selectedSection;

  @override
  Widget build(BuildContext context) {
    Widget section(String name) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      child: Text(
        name,
        style: const TextStyle(fontSize: 11, color: DesktopSidebar.muted),
      ),
    );
    Widget entry(
      String name,
      IconData icon,
      VoidCallback? action, {
      Key? key,
      int? section,
    }) => Tooltip(
      message: name,
      child: ListTile(
        key: key,
        selected: section != null && section == selectedSection,
        selectedTileColor: const Color(0xffdce6ef),
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(icon, size: 18),
        title: Text(name, style: const TextStyle(fontSize: 12)),
        onTap: action,
      ),
    );
    return DesktopSidebar(
      title: '登录与安全',
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          section('当前账号'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              username,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (onAccount != null)
            entry('账号安全', Icons.person_outline, onAccount, section: 0),
          if (onLogout != null)
            entry(
              loggingOut ? '正在退出…' : '退出登录',
              Icons.logout,
              loggingOut ? null : onLogout,
              key: const Key('logout'),
            ),
          if (onUsers != null) ...[
            section('账号与授权'),
            entry(
              '用户与访问范围',
              Icons.manage_accounts_outlined,
              onUsers,
              section: 1,
            ),
            entry('角色管理', Icons.badge_outlined, onRoles, section: 2),
            entry('登录会话', Icons.devices_outlined, onSessions, section: 3),
            section('入口与设备'),
            if (onNetwork != null)
              entry('网络访问入口', Icons.lan_outlined, onNetwork, section: 9),
            if (onKP != null) entry('KP 接入', Icons.link, onKP, section: 10),
            entry(
              'Web 白名单（内网 / 公网）',
              Icons.rule_outlined,
              onWhitelist,
              section: 4,
            ),
            entry(
              '设备申请与审批',
              Icons.phonelink_setup_outlined,
              onDevices,
              section: 5,
            ),
            entry(
              '设备证书（高级）',
              Icons.verified_user_outlined,
              onCertificates,
              section: 6,
            ),
            section('防护与记录'),
            entry('封禁与解封', Icons.block_outlined, onBans, section: 7),
          ] else
            section('访问记录'),
          entry('拦截与访问记录', Icons.receipt_long_outlined, onRecords, section: 8),
        ],
      ),
    );
  }
}
