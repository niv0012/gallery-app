import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Studio-logo watermark pinned to the bottom-right corner of the box it
/// is stacked in.
///
/// IMPORTANT: place this as a direct child of a [Stack] whose size is
/// exactly the size of the image/video/thumbnail — NOT the screen. That
/// is what makes the logo sit in the *image's* corner.
///
/// Sizing rules mirror `WatermarkService` (the version burned into
/// downloaded/shared files) so what the client sees on screen matches
/// what they get in their gallery:
///   * logo height  = [heightFraction] of the image's shorter side
///   * edge margin  = 3% of the image's shorter side
///   * logo width   <= 30% of the image width
class WatermarkOverlay extends StatelessWidget {
  final String url;
  final double heightFraction;
  final double minHeight;
  final double maxHeight;
  final double opacity;

  const WatermarkOverlay({
    super.key,
    required this.url,
    this.heightFraction = 0.12,
    this.minHeight = 14,
    this.maxHeight = 400,
    this.opacity = 0.7,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, c) {
            if (!c.maxWidth.isFinite || !c.maxHeight.isFinite) {
              return const SizedBox.shrink();
            }
            final shorter = math.min(c.maxWidth, c.maxHeight);
            final logoH = math
                .min(math.max(shorter * heightFraction, minHeight), maxHeight)
                .toDouble();
            final margin = shorter * 0.03;

            return Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(margin),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: c.maxWidth * 0.30),
                  child: Opacity(
                    opacity: opacity,
                    child: Image.network(
                      url,
                      height: logoH,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomRight,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
