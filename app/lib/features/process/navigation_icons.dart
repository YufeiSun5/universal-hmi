import 'package:flutter/material.dart';
import '../../shared/api.dart';

const navigationIcons = <String, (String, IconData)>{
  'station': ('站点', Icons.home_work_outlined),
  'home': ('房屋', Icons.home_outlined),
  'circle': ('空心圆', Icons.circle_outlined),
  'dot': ('实心圆', Icons.circle),
  'square': ('方形', Icons.crop_square),
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
  'district': ('区域', Icons.location_city_outlined),
  'location': ('位置', Icons.location_on_outlined),
  'route': ('线路', Icons.route_outlined),
  'network': ('管网', Icons.hub_outlined),
  'valve': ('阀门', Icons.tune),
  'tank': ('水箱', Icons.storage_outlined),
  'electricity': ('电力', Icons.bolt_outlined),
  'meter': ('仪表', Icons.av_timer_outlined),
  'fan': ('风机', Icons.wind_power_outlined),
  'equipment': ('设备台账', Icons.inventory_2_outlined),
  'tools': ('维护', Icons.build_outlined),
  'alarm': ('报警', Icons.notifications_outlined),
  'chart': ('趋势', Icons.show_chart),
  'report': ('报表', Icons.table_chart_outlined),
  'dashboard': ('总览', Icons.dashboard_outlined),
  'document': ('文档', Icons.description_outlined),
  'calendar': ('日历', Icons.calendar_month_outlined),
  'user': ('用户', Icons.person_outline),
  'certificate': ('证书', Icons.verified_user_outlined),
  'settings': ('设置', Icons.settings_outlined),
};

/// A leaf without an explicit choice uses its top-level directory's icon. This
/// remains stable when authorization exposes only one station or one screen.
IconData pageNavigationIcon(Json node, {Json? root}) {
  final own = navigationIcons[node['icon']];
  if (own != null) return own.$2;
  final inherited = navigationIcons[root?['icon']];
  return inherited?.$2 ?? Icons.home_work_outlined;
}
