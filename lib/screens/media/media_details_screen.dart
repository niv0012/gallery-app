import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/media/video_fallback_thumbnail.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../models/user.dart' show AppUserRole;
import '../../providers/auth_providers.dart'
    show apiClientProvider, authStateProvider;
import '../../providers/media_provider.dart';
import '../../providers/media_likes_comments_provider.dart';
import '../../services/download_service.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../services/share_service.dart';
import '../../services/share_service_impl.dart';
import '../../widgets/media/media_like_button.dart';
import '../../widgets/media/media_comments_section.dart';
import '../../widgets/media/download_complete_bottom_sheet.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import 'image_viewer_screen.dart';
import 'media_batch_workflows.dart';
import 'video_player_screen.dart';
import '../../core/theme/theme_context.dart';

/// Route arguments for [MediaDetailsScreen].
///
/// [mediaIds] is the ordered id list of the grid/search results the user
/// came from, so the Viewer can swipe through that same set. When absent
/// (e.g. a deep link), Details falls back to a single-item set.
class MediaDetailsArgs {
  final String mediaId;
  final List<String>? mediaIds;
  final String? heroTag;

  const MediaDetailsArgs({required this.mediaId, this.mediaIds, this.heroTag});
}

/// Media Details — full metadata + primary actions (favorite, delete,
/// open full-screen viewer/player) for a single photo or video.
class MediaDetailsScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final List<String>? mediaIds;
  final String? heroTag;

  const MediaDetailsScreen({
    super.key,
    required this.mediaId,
    this.mediaIds,
    this.heroTag,
  });

  @override
  ConsumerState<MediaDetailsScreen> createState() => _MediaDetailsScreenState();
}

class _MediaDetailsScreenState extends ConsumerState<MediaDetailsScreen> {
  static const ShareService _shareService = ShareServiceImpl();
  static const DownloadService _downloadService = DownloadServiceImpl();
  static const MediaFileCache _fileCache = MediaFileCache();
  Timer? _thumbnailRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshMedia();
      ref.read(mediaLikesCommentsProvider).fetchComments(widget.mediaId);
      ref.read(mediaLikesCommentsProvider).fetchLikes(widget.mediaId);
    });
  }

  Future<void> _refreshMedia() async {
    final controller = ref.read(mediaProvider);
    await controller.load();
    if (!mounted) return;

    final media = _find(controller.allMedia, widget.mediaId);
    if (media?.type != MediaType.video ||
        media?.remoteThumbnailUrl?.isNotEmpty == true ||
        media?.thumbnailPath.isNotEmpty == true) {
      _thumbnailRefreshTimer?.cancel();
      _thumbnailRefreshTimer = null;
    } else {
      _thumbnailRefreshTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshMedia(),
      );
    }
  }

  @override
  void dispose() {
    _thumbnailRefreshTimer?.cancel();
    super.dispose();
  }

  MediaModel? _find(List<MediaModel> all, String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> _shareMedia(BuildContext context, MediaModel media) async {
    if (kIsWeb) {
      final result = await _fileCache.bytesFor(media);
      if (result == null) return;
      if (!context.mounted) return;
      await _shareService.shareMediaBytes(
        context: context,
        bytes: result.bytes,
        fileName: result.fileName,
      );
      return;
    }
    final filePath = await _fileCache.localPathFor(media);
    if (filePath == null) return;
    if (!context.mounted) return;
    await _shareService.shareMedia(context: context, filePath: filePath);
  }

  Future<void> _downloadMedia(
      BuildContext context, WidgetRef ref, MediaModel media) async {
    bool saved = false;
    String? localPath;
    final apiClient = ref.read(apiClientProvider);

    if (kIsWeb) {
      final result = await _fileCache.bytesFor(media);
      if (result == null) return;
      if (!context.mounted) return;
      saved = await _downloadService.downloadBytes(
        context: context,
        bytes: result.bytes,
        fileName: result.fileName,
        mediaId: media.id,
        apiClient: apiClient,
      );
    } else {
      localPath = await _fileCache.localPathFor(media);
      if (localPath == null) return;
      if (!context.mounted) return;
      saved = await _downloadService.downloadOriginal(
        context: context,
        filePath: localPath,
        mediaId: media.id,
        apiClient: apiClient,
      );
    }

    if (saved && context.mounted) {
      await DownloadCompleteBottomSheet.show(
        context: context,
        fileName: media.fileName,
        size: media.size,
        thumbnailPath: localPath,
        filePath: localPath,
        media: media,
      );
    }
  }

  /// Saves to the OS photo/video gallery on mobile. On web there's no
  /// gallery to write into and no filesystem path to hand `gal`, so this
  /// mirrors [_downloadMedia]'s web branch and falls back to the same
  /// in-memory "save as" flow. Permission prompts and the success/failure
  /// snackbar are handled inside [DownloadService.saveToGallery] itself.
  Future<void> _saveMediaToGallery(
      BuildContext context, WidgetRef ref, MediaModel media) async {
    bool saved = false;
    String? localPath;
    final apiClient = ref.read(apiClientProvider);

    if (kIsWeb) {
      final result = await _fileCache.bytesFor(media);
      if (result == null) return;
      if (!context.mounted) return;
      saved = await _downloadService.downloadBytes(
        context: context,
        bytes: result.bytes,
        fileName: result.fileName,
        mediaId: media.id,
        apiClient: apiClient,
      );
    } else {
      localPath = await _fileCache.localPathFor(media);
      if (localPath == null) return;
      if (!context.mounted) return;
      saved = await _downloadService.saveToGallery(
        context: context,
        filePath: localPath,
        mediaId: media.id,
        apiClient: apiClient,
      );
    }

    if (saved && context.mounted) {
      await DownloadCompleteBottomSheet.show(
        context: context,
        fileName: media.fileName,
        size: media.size,
        thumbnailPath: localPath,
        filePath: localPath,
        media: media,
      );
    }
  }

  Future<void> _renameMedia(
      BuildContext context, WidgetRef ref, MediaModel media) async {
    final nameController = TextEditingController(text: media.fileName);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename media'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(hintText: 'Enter new file name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(nameController.text),
            child: Text('Save'),
          ),
        ],
      ),
    );

    if (newName == null || newName.trim().isEmpty) return;
    await ref
        .read(mediaProvider)
        .renameMediaById(mediaId: media.id, newFileName: newName);
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, MediaModel media) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_rounded, color: AppColors.error, size: 30),
            ),
            const SizedBox(height: 16),
            Text('Delete Photo?',
                style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.textOnDark : AppColors.text)),
            const SizedBox(height: 8),
            Text('This photo will be moved to trash.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle)),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.delete_rounded, color: Colors.white),
                label: const Text('Delete',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.border),
                ),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('Cancel',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.textOnDark : AppColors.text)),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    final controller = ref.read(mediaProvider);
    final backup = [media];
    controller.toggleSelected(media.id);
    await controller.batchDelete();

    if (!context.mounted) return;
    Navigator.of(context).pop();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.success,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: const Text('Moved to trash',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        action: SnackBarAction(
          label: 'Undo',
          textColor: Colors.white,
          onPressed: () async => controller.restoreDeletedMedia(backup),
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      messenger.hideCurrentSnackBar();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final isClientUser = auth.user?.role == AppUserRole.client;
    final c = ref.watch(mediaProvider);
    final media = _find(c.allMedia, widget.mediaId);

    if (media == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Media', showBack: true),
        body: Center(
          child: EmptyStateCard(
            icon: Icons.search_off_rounded,
            message: 'This media item no longer exists.',
          ),
        ),
      );
    }

    final ids = widget.mediaIds != null
        ? widget.mediaIds!.toSet().toList()
        : [media.id];
    final index = ids.indexOf(media.id);
    final safeIndex = index == -1 ? 0 : index;

    final path = media.displayPath;
    final isNetwork = media.isDisplayPathNetwork;
    final file = (!isNetwork && path.isNotEmpty) ? File(path) : null;
    final hasRealFile = isNetwork || (!kIsWeb && file != null && file.existsSync());

    // Video poster frame: separate from [path]/[file] above, since a
    // video's `displayPath` points at the video file itself (which
    // Image.* can't decode) — `displayThumbnailPath` is the actual
    // generated poster-frame JPEG (local or `thumbnail_url`).
    final videoThumbPath = media.displayThumbnailPath;
    final videoThumbIsNetwork = videoThumbPath.startsWith('http://') ||
        videoThumbPath.startsWith('https://');
    final videoThumbFile = (!videoThumbIsNetwork && videoThumbPath.isNotEmpty)
        ? File(videoThumbPath)
        : null;
    final hasVideoThumb = (videoThumbIsNetwork && videoThumbPath.isNotEmpty) ||
        (!kIsWeb && videoThumbFile != null && videoThumbFile.existsSync());

    void openFullScreen() {
      Navigator.of(context).pushNamed(
        media.type == MediaType.photo
            ? AppRoutes.imageViewer
            : AppRoutes.videoPlayer,
        arguments: media.type == MediaType.photo
            ? ImageViewerArgs(
                mediaIds: ids,
                initialIndex: safeIndex,
                readOnly: isClientUser,
              )
            : VideoPlayerArgs(
                mediaId: media.id,
                mediaIds: ids,
                initialIndex: safeIndex,
                readOnly: isClientUser,
              ),
      );
    }

    return Scaffold(
      appBar: CustomAppBar(
        title:
            media.type == MediaType.photo ? 'Photo Details' : 'Video Details',
        showBack: true,
        actions: [
          IconButton(
            tooltip:
                media.isFavorite ? 'Remove from favorites' : 'Add to favorites',
            onPressed: () => ref.read(mediaProvider).toggleFavorite(media.id),
            icon: Icon(
              media.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: media.isFavorite
                  ? AppColors.accent
                  : (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _MediaStitchBottomBar(
        isFavorite: media.isFavorite,
        isVideo: media.type == MediaType.video,
        showDelete: !isClientUser,
        onPrimary: openFullScreen,
        onFavorite: () => ref.read(mediaProvider).toggleFavorite(media.id),
        onDelete: () => _confirmDelete(context, ref, media),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: AppShadows.soft(
                    AppColors.primary,
                    opacity: 0.15,
                    blur: 40,
                    y: 16,
                  ),
                ),
                child: GestureDetector(
                  onTap: openFullScreen,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.65,
                      ),
                      child: AspectRatio(
                        aspectRatio: media.width > 0 && media.height > 0
                            ? media.width / media.height
                            : 1,
                        child: Hero(
                          tag: widget.heroTag ?? 'hero-media-${media.id}',
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (hasRealFile && media.type == MediaType.photo)
                                isNetwork
                                    ? Image.network(path,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            _MediaGradientPlaceholder(
                                                media: media))
                                    : Image.file(file!,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            _MediaGradientPlaceholder(
                                                media: media))
                              else if (media.type == MediaType.video &&
                                  hasVideoThumb)
                                videoThumbIsNetwork
                                    ? Image.network(videoThumbPath,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            VideoFallbackThumbnail(media: media, fit: BoxFit.contain))
                                    : Image.file(videoThumbFile!,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            _MediaGradientPlaceholder(
                                                media: media))
                              else if (media.type == MediaType.video)
                                VideoFallbackThumbnail(media: media, fit: BoxFit.contain)
                              else
                                _MediaGradientPlaceholder(media: media),
                              // Play affordance sits on top of whatever's
                              // behind it (real poster frame or the
                              // gradient fallback) — a video is always
                              // tappable-to-play here, whether or not a
                              // thumbnail was available to generate.
                              if (media.type == MediaType.video)
                                Center(
                                  child: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: Colors.white.withValues(alpha: 0.92),
                                    size: 56,
                                  ),
                                ),
                              if (media.type == MediaType.video && media.duration != null)
                                Positioned(
                                  right: AppSpacing.md,
                                  bottom: AppSpacing.md,
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.65),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      MediaFormatUtils.formatDuration(
                                          media.duration),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              SizedBox(height: AppSpacing.lg),

              // Extra actions (Share / Download / Move / Copy / Rename) —
              // previously only available from the full-screen player, now
              // also surfaced here on the Details page.
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  _DetailsActionChip(
                    icon: Icons.ios_share_rounded,
                    label: 'Share',
                    onTap: () => _shareMedia(context, media),
                  ),
                  _DetailsActionChip(
                    icon: Icons.download_rounded,
                    label: 'Download',
                    onTap: () => _downloadMedia(context, ref, media),
                  ),
                  _DetailsActionChip(
                    icon: Icons.add_photo_alternate_rounded,
                    label: 'Save to Gallery',
                    onTap: () => _saveMediaToGallery(context, ref, media),
                  ),
                  if (!isClientUser) ...[
                    _DetailsActionChip(
                      icon: Icons.drive_file_move_rounded,
                      label: 'Move',
                      onTap: () => MediaBatchWorkflows.openMove(
                        context: context,
                        mediaIds: [media.id],
                      ),
                    ),
                    _DetailsActionChip(
                      icon: Icons.copy_all_rounded,
                      label: 'Copy',
                      onTap: () => MediaBatchWorkflows.openCopy(
                        context: context,
                        mediaIds: [media.id],
                      ),
                    ),
                    _DetailsActionChip(
                      icon: Icons.drive_file_rename_outline_rounded,
                      label: 'Rename',
                      onTap: () => _renameMedia(context, ref, media),
                    ),
                  ],
                ],
              ),

              SizedBox(height: AppSpacing.lg),

              // Likes + Comments
              Consumer(builder: (context, ref, _) {
                final lc = ref.watch(mediaLikesCommentsProvider);

                // Prime the like cache from the server-seeded fields on
                // `media` (MediaRead.like_count / is_liked_by_me) the
                // first time this media is shown, so the button reflects
                // reality immediately instead of the (false, 0) default.
                // No-op once a real state is already cached.
                lc.seedLikeState(media);
                final likeState = lc.likeStateFor(media.id);

                // The `initState` already requests fresh comments when this screen opens.

                final likes = lc.likesForMedia(media.id);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        MediaLikeButton(
                          liked: likeState.liked,
                          likeCount: likeState.count,
                          onToggle: () => lc.toggleLike(media.id),
                        ),
                      ],
                    ),
                    if (likes.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                        child: Text(
                          'Liked by: ${likes.map((l) => l.userFullName).join(', ')}',
                          style: TextStyle(
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                              fontSize: 12),
                        ),
                      ),
                    const Divider(height: 24),
                    MediaCommentsSection(
                      comments: lc.commentsForMedia(media.id),
                      currentUserId: lc.currentUserId,
                      isLoading: lc.isLoading,
                      onAddTopLevel: (text) => lc.addComment(
                        mediaId: media.id,
                        text: text,
                        parentId: null,
                      ),
                      onReply: (parentId, text) => lc.addComment(
                        mediaId: media.id,
                        text: text,
                        parentId: parentId,
                      ),
                      onEdit: (commentId, newText) => lc.editOwnComment(
                        commentId: commentId,
                        newText: newText,
                      ),
                      onDelete: (commentId) => lc.deleteOwnComment(
                        commentId: commentId,
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      );
  }
}

/// Light-themed pill button used on the Details page's action row.
/// (Mirrors `_ActionChip` in [VideoPlayerScreen] but tuned for a white
/// card background instead of a dark video overlay.)
class _MediaGradientPlaceholder extends StatelessWidget {
  final MediaModel media;
  const _MediaGradientPlaceholder({required this.media});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(media.gradientArgb.first),
            Color(media.gradientArgb[1]),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: media.type == MediaType.photo
          ? Center(
              child: Icon(
                Icons.image_rounded,
                color: Colors.white.withValues(alpha: 0.92),
                size: 56,
              ),
            )
          : null,
    );
  }
}

class _DetailsActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DetailsActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: AppColors.primary),
      label: Text(
        label,
        style: TextStyle(
          color: (Theme.of(context).brightness == Brightness.dark
              ? AppColors.textOnDark
              : AppColors.text),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      onPressed: onTap,
      backgroundColor: (Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkSurface
          : AppColors.surface),
      side: BorderSide(color: context.borderColor),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    );
  }
}

class _MediaStitchBottomBar extends StatelessWidget {
  final bool isVideo;
  final bool isFavorite;
  final bool showDelete;
  final VoidCallback onPrimary;
  final VoidCallback onFavorite;
  final VoidCallback onDelete;

  const _MediaStitchBottomBar({
    required this.isVideo,
    required this.isFavorite,
    required this.showDelete,
    required this.onPrimary,
    required this.onFavorite,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface.withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.95),
        border: Border(
            top: BorderSide(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkBorder
                    : AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                    Expanded(
                      flex: 3,
                      child: FilledButton.icon(
                        onPressed: onPrimary,
                        icon: Icon(
                          isVideo ? Icons.play_arrow_rounded : Icons.zoom_in_rounded,
                        ),
                        label: Text(
                          isVideo ? 'Play Video' : 'View Full Screen',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: IconButton.filledTonal(
                        onPressed: onFavorite,
                        icon: Icon(
                          isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                        ),
                        tooltip: isFavorite ? 'Unfavorite' : 'Favorite',
                      ),
                    ),
                    if (showDelete) ...[
                      SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: IconButton.filledTonal(
                          onPressed: onDelete,
                          icon: Icon(Icons.delete_outline_rounded),
                          tooltip: 'Delete',
                          style: IconButton.styleFrom(
                            foregroundColor: AppColors.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ),
      ),
    );
  }
}
