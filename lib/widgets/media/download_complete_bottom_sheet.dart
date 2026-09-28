import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../screens/media/image_viewer_screen.dart';
import '../../screens/media/video_player_screen.dart';
import '../../core/theme/theme_context.dart';

/// Lightweight 'Download Complete' bottom sheet shown after a successful download or save.
/// Displays media thumbnail, file name, formatted size, and two action buttons:
/// 1. "Open File"
/// 2. "View in Download History"
class DownloadCompleteBottomSheet extends StatelessWidget {
  final String fileName;
  final int size;
  final String? thumbnailPath;
  final String? filePath;
  final MediaModel? media;

  const DownloadCompleteBottomSheet({
    super.key,
    required this.fileName,
    required this.size,
    this.thumbnailPath,
    this.filePath,
    this.media,
  });

  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required int size,
    String? thumbnailPath,
    String? filePath,
    MediaModel? media,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DownloadCompleteBottomSheet(
        fileName: fileName,
        size: size,
        thumbnailPath: thumbnailPath,
        filePath: filePath,
        media: media,
      ),
    );
  }

  Future<void> _openFile(BuildContext context) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Try system launcher if filePath exists
    if (!kIsWeb && filePath != null && filePath!.isNotEmpty) {
      final file = File(filePath!);
      if (file.existsSync()) {
        try {
          final uri = Uri.file(filePath!);
          final launched = await launchUrl(uri);
          if (launched) {
            if (context.mounted) nav.pop();
            return;
          }
        } catch (_) {
          // Fall through to in-app viewer fallback
        }
      }
    }

    // In-app viewer fallback if media object is present
    if (media != null) {
      nav.pop();
      if (media!.type == MediaType.video) {
        nav.pushNamed(
          AppRoutes.videoPlayer,
          arguments: VideoPlayerArgs(
            mediaId: media!.id,
            mediaIds: [media!.id],
            initialIndex: 0,
          ),
        );
      } else {
        nav.pushNamed(
          AppRoutes.imageViewer,
          arguments: ImageViewerArgs(
            mediaIds: [media!.id],
            initialIndex: 0,
          ),
        );
      }
      return;
    }

    // Web / no direct file launch fallback
    if (context.mounted) {
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved "$fileName" successfully.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  void _viewDownloadHistory(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context).pushNamed(AppRoutes.downloadHistory);
  }

  Widget _buildThumbnail() {
    Widget thumbWidget;

    if (!kIsWeb &&
        thumbnailPath != null &&
        thumbnailPath!.isNotEmpty &&
        File(thumbnailPath!).existsSync()) {
      thumbWidget = Image.file(
        File(thumbnailPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackIcon(),
      );
    } else if (!kIsWeb &&
        filePath != null &&
        filePath!.isNotEmpty &&
        File(filePath!).existsSync()) {
      thumbWidget = Image.file(
        File(filePath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackIcon(),
      );
    } else if (media != null &&
        media!.thumbnailPath.isNotEmpty &&
        File(media!.thumbnailPath).existsSync()) {
      thumbWidget = Image.file(
        File(media!.thumbnailPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackIcon(),
      );
    } else if (media != null &&
        media!.remoteThumbnailUrl != null &&
        media!.remoteThumbnailUrl!.isNotEmpty) {
      thumbWidget = Image.network(
        media!.remoteThumbnailUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackIcon(),
      );
    } else {
      thumbWidget = _buildFallbackIcon();
    }

    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.hardEdge,
      child: thumbWidget,
    );
  }

  Widget _buildFallbackIcon() {
    final isVideo = media?.type == MediaType.video ||
        fileName.toLowerCase().endsWith('.mp4') ||
        fileName.toLowerCase().endsWith('.mov');
    return Center(
      child: Icon(
        isVideo ? Icons.movie_outlined : Icons.image_outlined,
        color: AppColors.primary,
        size: 28,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(AppSpacing.md),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: AppShadows.soft(AppColors.primary),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Header icon + title
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.success,
                  size: 26,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Download Complete',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Saved to your local device',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: context.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Media Card (Thumbnail + Filename + Size)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                _buildThumbnail(),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary,
                                ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        MediaFormatUtils.formatFileSize(size),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: context.textMuted,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // Primary Action: Open File
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            onPressed: () => _openFile(context),
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            label: const Text(
              'Open File',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          // Secondary Action: View in Download History
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: context.textPrimary,
              side: BorderSide(color: context.borderColor),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            onPressed: () => _viewDownloadHistory(context),
            icon: const Icon(Icons.history_rounded, size: 20),
            label: const Text(
              'View in Download History',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
