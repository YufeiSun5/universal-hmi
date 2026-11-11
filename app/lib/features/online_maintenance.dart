import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/desktop_sidebar.dart';
import 'security_navigation.dart';
import 'security_workspace.dart';

/// The same authorized forms are available in every client. This page never
/// exposes local listener/KP configuration through the online maintenance entry.
class OnlineMaintenancePage extends StatefulWidget {
  const OnlineMaintenancePage({
    super.key,
    required this.api,
    required this.username,
    required this.canManageUsers,
    required this.canApproveDevices,
    required this.canManageCertificates,
    required this.canEditEquipment,
    required this.canEditEquipmentNavigation,
  });
  final PlatformApi api;
  final String username;
  final bool canManageUsers, canApproveDevices, canManageCertificates;
  final bool canEditEquipment, canEditEquipmentNavigation;
  @override
  State<OnlineMaintenancePage> createState() => _OnlineMaintenancePageState();
}

class _OnlineMaintenancePageState extends State<OnlineMaintenancePage> {
  final scaffold = GlobalKey<ScaffoldState>();
  late int section = widget.canApproveDevices
      ? 5
      : widget.canManageCertificates
      ? 6
      : widget.canManageUsers
      ? 1
      : widget.canEditEquipment
      ? 13
      : 8;
  void select(int next) {
    setState(() => section = next);
    scaffold.currentState?.closeDrawer();
  }

  Widget directory() => SecurityNavigation(
    title: '线上运维',
    username: widget.username,
    selectedSection: section,
    onRecords: () => select(8),
    onUsers: widget.canManageUsers ? () => select(1) : null,
    onRoles: widget.canManageUsers ? () => select(2) : null,
    onSessions: widget.canManageUsers ? () => select(3) : null,
    onDevices: widget.canApproveDevices ? () => select(5) : null,
    onCertificates: widget.canManageCertificates ? () => select(6) : null,
    onEquipment: widget.canEditEquipment ? () => select(13) : null,
  );
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 850;
    return Scaffold(
      key: scaffold,
      appBar: AppBar(
        title: const Text('线上运维'),
        actions: [
          if (narrow)
            IconButton(
              key: const Key('maintenance-menu'),
              tooltip: '运维目录',
              onPressed: () => scaffold.currentState?.openDrawer(),
              icon: const Icon(Icons.menu),
            ),
        ],
      ),
      drawer: narrow ? Drawer(child: SafeArea(child: directory())) : null,
      body: Row(
        children: [
          if (!narrow)
            SizedBox(width: DesktopSidebar.width, child: directory()),
          Expanded(
            child: SecurityWorkspace(
              api: widget.api,
              section: section,
              canManageUsers: widget.canManageUsers,
              canManageSecurity: false,
              canApproveDevices: widget.canApproveDevices,
              canManageCertificates: widget.canManageCertificates,
              canEditEquipment: widget.canEditEquipment,
              canEditEquipmentNavigation: widget.canEditEquipmentNavigation,
            ),
          ),
        ],
      ),
    );
  }
}
