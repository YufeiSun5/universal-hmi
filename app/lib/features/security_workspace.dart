import 'package:flutter/material.dart';
import '../shared/api.dart';
import 'security.dart';
import 'security_page.dart';
import 'security_layout.dart';
import 'network_access.dart';
import 'kp_settings.dart';
import 'public_access.dart';
import 'public_access_events.dart';
import 'public_bans.dart';
import 'device_registrations.dart';
import 'device_certificates.dart';
import 'equipment/workspace.dart';
import 'online_connections.dart';

/// Each visited category retains its page stack and unsaved form while switching.
/// Backend permissions and mutation/confirmation logic remain in their panels.
class SecurityWorkspace extends StatefulWidget {
  const SecurityWorkspace({
    super.key,
    required this.api,
    required this.section,
    required this.canManageUsers,
    this.canManageSecurity,
    this.canApproveDevices = false,
    this.canManageCertificates = false,
    this.canManagePublicBans = false,
    this.canEditEquipment = false,
    this.canEditEquipmentNavigation = false,
    this.accountBuilder,
    this.canViewOnline = false,
  });
  final PlatformApi api;
  final int section;
  final bool canManageUsers;
  final bool? canManageSecurity;
  final bool canApproveDevices, canManageCertificates, canManagePublicBans;
  final bool canEditEquipment, canEditEquipmentNavigation;
  final WidgetBuilder? accountBuilder;
  final bool canViewOnline;
  @override
  State<SecurityWorkspace> createState() => _SecurityWorkspaceState();
}

class _SecurityWorkspaceState extends State<SecurityWorkspace> {
  final Set<int> visited = {};
  bool get admin => widget.canManageSecurity ?? widget.canManageUsers;
  bool allowed(int section) => switch (section) {
    0 || 8 => true,
    1 || 2 || 3 => widget.canManageUsers,
    5 => admin || widget.canApproveDevices,
    6 => admin || widget.canManageCertificates,
    7 => admin || widget.canManagePublicBans,
    4 || 9 || 10 => admin,
    13 => widget.canEditEquipment,
    14 => widget.canViewOnline,
    _ => false,
  };
  Widget category(BuildContext context, int section) => switch (section) {
    0 =>
      widget.accountBuilder?.call(context) ??
          const Center(child: Text('当前账号未提供账号管理入口')),
    14 => OnlineConnectionsPanel(api: widget.api),
    1 => SecurityPanel(api: widget.api),
    2 => SecurityPanel(api: widget.api, initialTab: 3),
    3 => SecurityPanel(api: widget.api, initialTab: 1),
    4 => PublicAccessPanel(api: widget.api),
    5 => DeviceRegistrationsPanel(
      api: widget.api,
      canConfirmCertificates: admin || widget.canManageCertificates,
    ),
    6 => DeviceCertificatesPanel(api: widget.api),
    7 => PublicBansPanel(api: widget.api, canManuallyBan: admin),
    9 => NetworkAccessPage(api: widget.api),
    10 => KPSettingsPage(api: widget.api),
    13 => EquipmentWorkspace(
      api: widget.api,
      canEdit: widget.canEditEquipment,
      canEditNavigation: widget.canEditEquipmentNavigation,
    ),
    _ => PublicAccessEventsPanel(api: widget.api),
  };
  @override
  Widget build(BuildContext context) {
    final selected = allowed(widget.section) ? widget.section : 8;
    visited.add(selected);
    return SecurityTheme(
      child: Stack(
        children: [
          for (final section in visited)
            if (allowed(section))
              Positioned.fill(
                key: ValueKey(section),
                child: Offstage(
                  offstage: section != selected,
                  child: TickerMode(
                    enabled: section == selected,
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (context) => SecurityPageScope(
                          root: true,
                          child: Builder(
                            builder: (context) => category(context, section),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
