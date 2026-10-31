import 'package:flutter/widgets.dart';

/// Native widgets already share Flutter's pointer dispatch.
class PlatformPointerShield extends StatelessWidget {
  const PlatformPointerShield({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
