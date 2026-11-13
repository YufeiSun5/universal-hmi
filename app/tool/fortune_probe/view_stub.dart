import 'package:flutter/material.dart';
import 'bridge.dart';

class ProbeView extends StatelessWidget {
  const ProbeView({super.key, required this.bridge});
  final ProbeBridge bridge;
  @override
  Widget build(BuildContext context) =>
      const Text('This probe targets Windows/Web');
}

Future<void> writeReport(Map<String, dynamic> report) async {}
