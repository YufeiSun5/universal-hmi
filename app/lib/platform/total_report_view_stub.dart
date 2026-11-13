import 'package:flutter/material.dart';
import '../features/total_reports/bridge.dart';

class TotalReportView extends StatelessWidget {
  const TotalReportView({super.key, required this.bridge});
  final TotalReportBridge bridge;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('请使用浏览器或Windows客户端打开总统计报表。'));
}
