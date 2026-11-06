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

/// Each visited category retains its page stack and unsaved form while switching.
/// Backend permissions and mutation/confirmation logic remain in their panels.
class SecurityWorkspace extends StatefulWidget {
  const SecurityWorkspace({
    super.key,
    required this.api,
    required this.section,
    required this.canManageUsers,
    this.accountBuilder,
  });
  final PlatformApi api;
  final int section;
  final bool canManageUsers;
  final WidgetBuilder? accountBuilder;
  @override
  State<SecurityWorkspace> createState() => _SecurityWorkspaceState();
}

class _SecurityWorkspaceState extends State<SecurityWorkspace> {
  final Set<int> visited = {};
  Widget category(BuildContext context, int section) => switch (section) {
    0 =>
      widget.accountBuilder?.call(context) ??
          const Center(child: Text('当前账号未提供账号管理入口')),
    1 => SecurityPanel(api: widget.api),
    2 => SecurityPanel(api: widget.api, initialTab: 3),
    3 => SecurityPanel(api: widget.api, initialTab: 1),
    4 => PublicAccessPanel(api: widget.api),
    5 => DeviceRegistrationsPanel(api: widget.api),
    6 => DeviceCertificatesPanel(api: widget.api),
    7 => PublicBansPanel(api: widget.api),
    9 => NetworkAccessPage(api: widget.api),
    10 => KPSettingsPage(api: widget.api),
    _ => PublicAccessEventsPanel(api: widget.api),
  };
  @override
  Widget build(BuildContext context) {
    final selected =
        !widget.canManageUsers && widget.section != 0 && widget.section != 8
        ? 8
        : widget.section;
    visited.add(selected);
    return SecurityTheme(
      child: Stack(
        children: [
          for (final section in visited)
            if (widget.canManageUsers || section == 0 || section == 8)
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
