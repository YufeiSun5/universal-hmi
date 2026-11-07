import 'package:flutter/material.dart';
import '../shared/api.dart';

const maintenanceCapabilities = {
  'user_management': '用户与权限管理',
  'device_approval': '设备申请审批',
  'certificate_management': '设备证书确认与撤销',
  'equipment_edit': '设备台账编辑',
};

/// UI choices mirror the server's delegation ceiling; the service remains the
/// authority and rechecks old/new grants, role members and resource scope.
class GrantEditorPolicy {
  const GrantEditorPolicy(this.limits);
  final Json? limits;
  bool get admin =>
      limits?['all_stations'] == true &&
      (limits?['roles'] as List? ?? []).contains('admin');
  bool get engineer =>
      limits?['all_stations'] == true &&
      (limits?['roles'] as List? ?? []).contains('engineer');
  bool role(String role) =>
      limits == null ||
      role == 'viewer' ||
      role == 'operator' ||
      (limits?['roles'] as List? ?? []).contains(role);
  bool capability(String key) {
    if (limits == null) return true;
    return switch (key) {
      'user_management' ||
      'device_approval' ||
      'certificate_management' => admin || limits?[key] == true,
      'equipment_edit' => engineer || limits?[key] == true,
      'control' => limits?['grant_control'] == true,
      _ => limits?[key] == true,
    };
  }

  bool screen(String id) =>
      limits == null ||
      limits?['all_stations'] == true ||
      (limits?['screen_ids'] as List? ?? []).contains(id);
  bool externalScreen(String id) =>
      limits == null ||
      engineer ||
      (limits?['external_screen_ids'] as List? ?? []).contains(id);
}

class MaintenancePermissions extends StatelessWidget {
  const MaintenancePermissions({
    super.key,
    required this.values,
    required this.onChanged,
    required this.policy,
    this.enabled = true,
  });
  final Map<String, bool> values;
  final void Function(String, bool) onChanged;
  final GrantEditorPolicy policy;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      const Text('线上运维权限', style: TextStyle(fontWeight: FontWeight.w600)),
      const Text('适用于 Windows、网页、KP 和手机端；用户授权不得超出操作者的权限和数据范围。'),
      for (final entry in maintenanceCapabilities.entries)
        CheckboxListTile(
          key: ValueKey('grant-${entry.key}'),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(entry.value),
          value: values[entry.key] == true,
          onChanged: enabled && policy.capability(entry.key)
              ? (v) => onChanged(entry.key, v == true)
              : null,
        ),
    ],
  );
}
