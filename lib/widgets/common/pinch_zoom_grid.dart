import 'package:flutter/material.dart';
import 'pinch_zoom_handler.dart';

class PinchZoomGrid extends StatefulWidget {
  const PinchZoomGrid({
    super.key,
    required this.child,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final Widget child;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  State<PinchZoomGrid> createState() => _PinchZoomGridState();
}

class _PinchZoomGridState extends State<PinchZoomGrid> {
  double _lastScale = 1.0;
  DateTime _lastEventTime = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return PinchZoomHandler(
      onZoomIn: widget.onZoomIn,
      onZoomOut: widget.onZoomOut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (details) {
          _lastScale = 1.0;
        },
        onScaleUpdate: (details) {
          if (details.pointerCount < 2) return;
          final now = DateTime.now();
          if (now.difference(_lastEventTime).inMilliseconds < 150) return;

          if (details.scale > _lastScale * 1.1) {
            widget.onZoomIn();
            _lastScale = details.scale;
            _lastEventTime = now;
          } else if (details.scale < _lastScale * 0.9) {
            widget.onZoomOut();
            _lastScale = details.scale;
            _lastEventTime = now;
          }
        },
        child: widget.child,
      ),
    );
  }
}
