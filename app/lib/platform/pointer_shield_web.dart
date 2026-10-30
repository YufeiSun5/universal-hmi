import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:web/web.dart' as web;

/// Keep DOM iframe events in the host while Flutter handles the overlay UI.
/// The transparent element covers only the child's laid-out bounds.
class PlatformPointerShield extends StatelessWidget {
  const PlatformPointerShield({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: HtmlElementView.fromTagName(
          tagName: 'div',
          isVisible: false,
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          onElementCreated: (element) {
            final shield = element as web.HTMLDivElement;
            shield.setAttribute('data-hmi-pointer-shield', '');
            shield.style
              ..width = '100%'
              ..height = '100%'
              ..pointerEvents = 'auto';
          },
        ),
      ),
      child,
    ],
  );
}
