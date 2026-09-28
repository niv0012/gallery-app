import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// Drop-in [Image.network] replacement that never shows Flutter's default
/// red-X error screen.
///
/// This is the actual fix for the studio-profile crash (Task 9 in the
/// cover-photo/portfolio task plan): a handful of call sites — the cover
/// image, logo, portfolio grid, and fullscreen swipe viewer on
/// `studio_profile_screen.dart` — called `Image.network` directly with no
/// guard at all, so an empty string (`''`, the old "not set yet" default
/// for `coverUrl`/`galleryUrls`) or an unreachable URL blew up the whole
/// screen instead of just failing to render one image.
///
/// Shows [placeholderIcon] (inside a plain [AppColors.background] box)
/// whenever:
///   - [url] is null or empty — never even attempts the network request.
///   - the request fails — via [Image.network]'s `errorBuilder`.
///
/// Everything else ([fit], [width], [height], [borderRadius]) behaves the
/// same as a normal `Image.network` call; wrap the call site's existing
/// `ClipRRect`/`ClipOval` around this the same way it wrapped the raw
/// `Image.network` before, or pass [borderRadius] here instead if there
/// wasn't already an outer clip.
class SafeNetworkImage extends StatelessWidget {
  const SafeNetworkImage(
    this.url, {
    super.key,
    this.placeholderIcon = Icons.image_rounded,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.iconSize = 28,
    this.loadingBuilder,
  });

  final String? url;
  final IconData placeholderIcon;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final double iconSize;

  /// Optional passthrough to [Image.network]'s own `loadingBuilder`, for
  /// call sites that already show their own progress indicator while the
  /// image loads (e.g. the Showcase Portfolio grid). Has no effect on the
  /// empty/null or error cases above — those always show [placeholderIcon].
  final Widget Function(
          BuildContext context, Widget child, ImageChunkEvent? loadingProgress)?
      loadingBuilder;

  bool get _hasUrl => url != null && url!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(
      icon: placeholderIcon,
      iconSize: iconSize,
      width: width,
      height: height,
    );

    if (!_hasUrl) {
      return borderRadius == null
          ? placeholder
          : ClipRRect(borderRadius: borderRadius!, child: placeholder);
    }

    final image = Image.network(
      url!,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => placeholder,
      loadingBuilder: loadingBuilder,
    );

    return borderRadius == null
        ? image
        : ClipRRect(borderRadius: borderRadius!, child: image);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.iconSize,
    this.width,
    this.height,
  });

  final IconData icon;
  final double iconSize;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: context.bgColor.withValues(alpha: 0.8),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: context.textMuted),
    );
  }
}
