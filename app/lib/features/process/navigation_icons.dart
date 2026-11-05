import 'package:flutter/material.dart';
import '../../shared/api.dart';

const navigationIcons = <String, (String, IconData)>{
  'station': ('站点', Icons.home_work_outlined),
  'factory': ('热源/厂区', Icons.factory_outlined),
  'process': ('工艺', Icons.account_tree_outlined),
  'water': ('水', Icons.water_drop_outlined),
  'heat': ('供热', Icons.local_fire_department_outlined),
  'pump': ('泵', Icons.settings_outlined),
  'temperature': ('温度', Icons.thermostat_outlined),
  'pressure': ('压力', Icons.speed_outlined),
  'building': ('建筑', Icons.apartment_outlined),
  'map': ('地图', Icons.map_outlined),
  'folder': ('目录', Icons.folder_open),
};

/// A leaf without an explicit choice uses its top-level directory's icon. This
/// remains stable when authorization exposes only one station or one screen.
IconData pageNavigationIcon(Json node, {Json? root}) {
  final own = navigationIcons[node['icon']];
  if (own != null) return own.$2;
  final inherited = navigationIcons[root?['icon']];
  return inherited?.$2 ?? Icons.home_work_outlined;
}
