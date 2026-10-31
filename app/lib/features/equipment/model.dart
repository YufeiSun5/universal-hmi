import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../process/runtime_chrome.dart';

const ledgerInk = RuntimeStyle.ink;
const ledgerAccent = RuntimeStyle.accent;
const ledgerLine = RuntimeStyle.line;
const equipmentKinds = ['水泵', '换热器', '阀门', '仪表', '水箱', '电气设备', '其他'];
IconData equipmentIcon(String kind) => switch (kind) {
  '水泵' => Icons.cyclone,
  '换热器' => Icons.view_week_outlined,
  '阀门' => Icons.settings_input_component_outlined,
  '仪表' => Icons.speed,
  '水箱' => Icons.water_drop_outlined,
  '电气设备' => Icons.electrical_services,
  _ => Icons.precision_manufacturing_outlined,
};
String value(Json d, String key) => d[key]?.toString() ?? '';
