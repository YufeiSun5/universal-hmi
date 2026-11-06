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
    this.title = '登录与安全',
    this.onEquipment,
  });

  final String username;
  final VoidCallback onRecords;
  final VoidCallback? onAccount, onLogout, onUsers, onRoles, onSessions;
  final VoidCallback? onWhitelist, onDevices, onCertificates, onBans;
  final bool loggingOut;
  final VoidCallback? onNetwork;
  final VoidCallback? onKP;
  final int? selectedSection;
  final String title;
  final VoidCallback? onEquipment;

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
      title: title,
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
          if (onUsers != null || onRoles != null || onSessions != null)
            section('账号与授权'),
          if (onUsers != null)
            entry(
              '用户与访问范围',
              Icons.manage_accounts_outlined,
              onUsers,
              section: 1,
            ),
          if (onRoles != null)
            entry('角色管理', Icons.badge_outlined, onRoles, section: 2),
          if (onSessions != null)
            entry('登录会话', Icons.devices_outlined, onSessions, section: 3),
          if (onNetwork != null ||
              onKP != null ||
              onWhitelist != null ||
              onDevices != null ||
              onCertificates != null)
            section('入口与设备'),
          if (onNetwork != null)
            entry('网络访问入口', Icons.lan_outlined, onNetwork, section: 9),
          if (onKP != null) entry('KP 接入', Icons.link, onKP, section: 10),
          if (onWhitelist != null)
            entry(
              'Web 白名单（内网 / 公网）',
              Icons.rule_outlined,
              onWhitelist,
              section: 4,
            ),
          if (onDevices != null)
            entry(
              '设备申请与审批',
              Icons.phonelink_setup_outlined,
              onDevices,
              section: 5,
            ),
          if (onCertificates != null)
            entry(
              '设备证书确认与撤销',
              Icons.verified_user_outlined,
              onCertificates,
              section: 6,
            ),
          if (onEquipment != null) ...[
            section('设备档案'),
            entry(
              '设备台账维护',
              Icons.inventory_2_outlined,
              onEquipment,
              section: 13,
            ),
          ],
          section('防护与记录'),
          if (onBans != null)
            entry('封禁与解封', Icons.block_outlined, onBans, section: 7),
          entry('拦截与访问记录', Icons.receipt_long_outlined, onRecords, section: 8),
        ],
      ),
    );
  }
}
