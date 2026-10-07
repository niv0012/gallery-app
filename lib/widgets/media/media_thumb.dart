import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/media_model.dart';

/// Renders the actual photo (or a video's poster thumbnail) for a
/// [MediaModel], on disk or over the network, falling back to a soft
/// gradient + icon placeholder when there's nothing to show yet (no
/// path never crashes a card, it just looks like a normal placeholder.
///
/// This is the public, reusable version of the thumbnail logic that
/// used to live only inside `MediaGridScreen` (`_MediaThumbnail`) —
/// pulled out here so album cards, folder tiles, and folder browsing
/// screens can all show a real cover image instead of a static icon.
import 'video_fallback_thumbnail.dart';

class MediaThumb extends StatelessWidget {
  final MediaModel media;
  final BoxFit fit;

  /// Decode width in physical pixels. Grid tiles never need the full
  /// original decoded in memory; 480 keeps thumbnails sharp while cutting
  /// memory use and scroll jank. Pass a larger value for hero-sized uses.
  final int cacheWidth;

  /// When true, always loads the full-resolution original (`remoteUrl`)
  /// instead of the server-generated compressed thumbnail. Use this for
  /// full-screen / detail views. Defaults to false (grid-safe thumbnails).
  final bool fullQuality;

  const MediaThumb({
    super.key,
    required this.media,
    this.fit = BoxFit.cover,
    this.cacheWidth = 480,
    this.fullQuality = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        int? dynamicCacheWidth;
        if (!fullQuality) {
          if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
            final ratio = MediaQuery.of(context).devicePixelRatio;
            dynamicCacheWidth = math.min(1080, (constraints.maxWidth * ratio).round());
          } else {
            dynamicCacheWidth = math.min(1080, cacheWidth);
          }
        }

        final path = media.type == MediaType.photo && kIsWeb
            ? media.displayThumbnailPath
            : media.displayPath;
        final isNetwork = media.isDisplayPathNetwork;

        if (media.type == MediaType.photo) {
          if (isNetwork) {
            // fullQuality=true → always use the original file_url (full-res).
            // fullQuality=false → prefer server thumbnail for grid performance.
            final thumb = media.remoteThumbnailUrl;
            final url = fullQuality
                ? (media.remoteUrl ?? path)
                : ((thumb != null && thumb.isNotEmpty) ? thumb : path);
            return CachedNetworkImage(
              imageUrl: url,
              fit: fit,
              memCacheWidth: dynamicCacheWidth,
              errorWidget: (context, url, error) => _Placeholder(media: media),
              placeholder: (context, url) => _Placeholder(media: media),
            );
          }
          if (!kIsWeb && path.isNotEmpty && File(path).existsSync()) {
            return Image.file(
              File(path),
              fit: fit,
              cacheWidth: dynamicCacheWidth,
              errorBuilder: (context, error, stackTrace) =>
                  _Placeholder(media: media),
            );
          }
        } else {
          final thumbPath = media.displayThumbnailPath;
          final isThumbNetwork =
              thumbPath.startsWith('http://') || thumbPath.startsWith('https://');
          if (isThumbNetwork) {
            return CachedNetworkImage(
              imageUrl: thumbPath,
              fit: fit,
              memCacheWidth: dynamicCacheWidth,
              errorWidget: (context, url, error) =>
                  VideoFallbackThumbnail(media: media, fit: fit),
              placeholder: (context, url) =>
                  VideoFallbackThumbnail(media: media, fit: fit),
            );
          } else if (!kIsWeb &&
              thumbPath.isNotEmpty &&
              File(thumbPath).existsSync()) {
            return Image.file(
              File(thumbPath),
              fit: fit,
              cacheWidth: dynamicCacheWidth,
              errorBuilder: (context, error, stackTrace) =>
                  _Placeholder(media: media),
            );
          }
        }
        return media.type == MediaType.video
            ? VideoFallbackThumbnail(media: media, fit: fit)
            : _Placeholder(media: media);
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  final MediaModel media;

  const _Placeholder({required this.media});

  @override
  Widget build(BuildContext context) {
    final colors = media.gradientArgb.length >= 2
        ? [Color(media.gradientArgb.first), Color(media.gradientArgb[1])]
        : [AppColors.softWash.colors.first, AppColors.softWash.colors.last];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          media.type == MediaType.photo
              ? Icons.image_rounded
              : Icons.videocam_rounded,
          color: Colors.white.withValues(alpha: 0.94),
          size: 26,
        ),
      ),
    );
  }
}
