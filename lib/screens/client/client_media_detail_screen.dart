import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../providers/auth_providers.dart' show apiClientProvider;
import '../../providers/media_likes_comments_provider.dart';
import '../../services/download_service.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../services/permission_service.dart';
import '../../services/share_service.dart';
import '../../services/share_service_impl.dart';
import '../../widgets/media/media_like_button.dart';
import '../../widgets/media/media_comments_section.dart';
import '../../widgets/media/download_complete_bottom_sheet.dart';
import '../../widgets/media/media_thumb.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../media/image_viewer_screen.dart';
import '../media/video_player_screen.dart';

/// Route arguments for [ClientMediaDetailScreen].
class ClientMediaDetailArgs {
  final String mediaId;
  final MediaModel media;
  final List<String>? mediaIds;
  final String? heroTag;

  const ClientMediaDetailArgs({
    required this.mediaId,
    required this.media,
    this.mediaIds,
    this.heroTag,
  });
}

/// Client-facing Media Details — metadata + primary actions
/// (like, comment, download, save to gallery, share) for shared gallery media.
///
/// Like [MediaDetailsScreen] but:
/// - No favorite flag (studios use favorite, clients use like)
/// - No delete action
/// - Download requires storage permission check
class ClientMediaDetailScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final MediaModel media;
  final List<String>? mediaIds;
  final String? heroTag;

  const ClientMediaDetailScreen({
    super.key,
    required this.mediaId,
    required this.media,
    this.mediaIds,
    this.heroTag,
  });

  @override
  ConsumerState<ClientMediaDetailScreen> createState() =>
      _ClientMediaDetailScreenState();
}

class _ClientMediaDetailScreenState
    extends ConsumerState<ClientMediaDetailScreen> {
  static const ShareService _shareService = ShareServiceImpl();
  static const DownloadService _downloadService = DownloadServiceImpl();
  static const MediaFileCache _fileCache = MediaFileCache();

  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(mediaLikesCommentsProvider).seedLikeState(widget.media);
      ref.read(mediaLikesCommentsProvider).fetchComments(widget.mediaId);
      ref.read(mediaLikesCommentsProvider).fetchLikes(widget.mediaId);
    });
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

  /// Request storage permission before attempting download.
  /// Shows permission dialog and handles permanent denial.
  Future<bool> _requestStoragePermission(BuildContext context) async {
    final permService = PermissionService.instance;
    final granted = await permService.checkAndRequestStoragePermission();

    if (!granted && context.mounted) {
      final isPermanent = await permService.isPermanentlyDenied(
        Platform.isAndroid ? Permission.photos : Permission.photos,
      );

      if (!context.mounted) return false;

      if (isPermanent) {
        _showPermissionDeniedDialog(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission is required to download.'),
          ),
        );
      }
      return false;
    }

    return granted;
  }

  void _showPermissionDeniedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Storage Permission Denied'),
        content: Text(
          'Enable storage access in Settings to download media.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              PermissionService.instance.openAppSettingsPage();
            },
            child: Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadMedia(
    BuildContext context,
    WidgetRef ref,
    MediaModel media,
  ) async {
    // Check permission before download
    if (!await _requestStoragePermission(context)) return;

    setState(() => _isDownloading = true);

    try {
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
          isClientUser: true,
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
          isClientUser: true,
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
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  /// Saves to the OS photo/video gallery on mobile.
  /// On web falls back to the same in-memory "save as" flow.
  /// Permission prompts are handled inside [DownloadService.saveToGallery].
  Future<void> _saveMediaToGallery(
    BuildContext context,
    WidgetRef ref,
    MediaModel media,
  ) async {
    // Check permission before save
    if (!await _requestStoragePermission(context)) return;

    setState(() => _isDownloading = true);

    try {
      final apiClient = ref.read(apiClientProvider);

      if (kIsWeb) {
        final result = await _fileCache.bytesFor(media);
        if (result == null) return;
        if (!context.mounted) return;
        await _downloadService.downloadBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
          mediaId: media.id,
          apiClient: apiClient,
          isClientUser: true,
        );
      } else {
        final localPath = await _fileCache.localPathFor(media);
        if (localPath == null) return;
        if (!context.mounted) return;
        await _downloadService.saveToGallery(
          context: context,
          filePath: localPath,
          mediaId: media.id,
          apiClient: apiClient,
          isClientUser: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  /// Opens the shared full-screen viewer (swipeable across [widget.mediaIds]
  /// when the caller provided the full set — otherwise just this one item).
  /// [ImageViewerScreen]/[VideoPlayerScreen] key their own internal Hero
  /// tag off each media's id, so no external `heroTag` param is needed
  /// here.
  void _openViewer(BuildContext context, MediaModel media) {
    final ids = widget.mediaIds ?? [media.id];
    final index = ids.indexOf(media.id);
    final initialIndex = index < 0 ? 0 : index;

    if (media.type == MediaType.video) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            mediaId: media.id,
            mediaIds: ids,
            initialIndex: initialIndex,
            mediaItems: [media],
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
            mediaIds: ids,
            initialIndex: initialIndex,
            mediaItems: [media],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final likesComments = ref.watch(mediaLikesCommentsProvider);
    final likeState = likesComments.likeStateFor(media.id);
    final commentCount = likesComments.commentsForMedia(media.id).length;

    return Scaffold(
      appBar: CustomAppBar(
        title: media.fileName,
        showBack: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Media preview thumbnail
            Container(
              width: double.infinity,
              height: 300,
              color: Colors.black12,
              child: GestureDetector(
                onTap: () => _openViewer(context, media),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Hero(
                      tag: widget.heroTag ?? media.id,
                      child: MediaThumb(
                          media: media, fit: BoxFit.cover, cacheWidth: 1080),
                    ),
                    if (media.type == MediaType.video)
                      Center(
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(180),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // File info
                  Text(
                    media.fileName,
                    style: Theme.of(context).textTheme.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${MediaFormatUtils.formatFileSize(media.size)} • '
                        '${MediaFormatUtils.formatResolution(media.width, media.height)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Uploaded ${MediaFormatUtils.formatDate(media.createdAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                  SizedBox(height: 16),

                  // Action buttons
                  Wrap(
                    spacing: 12,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isDownloading
                            ? null
                            : () => _downloadMedia(context, ref, media),
                        icon: _isDownloading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Theme.of(context).primaryColor,
                                  ),
                                ),
                              )
                            : Icon(Icons.download),
                        label: Text('Download'),
                      ),
                      if (!kIsWeb)
                        OutlinedButton.icon(
                          onPressed: _isDownloading
                              ? null
                              : () => _saveMediaToGallery(context, ref, media),
                          icon: Icon(Icons.photo_library),
                          label: Text('Save'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _shareMedia(context, media),
                        icon: Icon(Icons.share),
                        label: Text('Share'),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),

                  // Like and comment counts
                  Row(
                    children: [
                      Expanded(
                        child: MediaLikeButton(
                          liked: likeState.liked,
                          likeCount: likeState.count,
                          onToggle: () => ref
                              .read(mediaLikesCommentsProvider)
                              .toggleLike(media.id),
                        ),
                      ),
                      Text('$commentCount comments'),
                    ],
                  ),
                  SizedBox(height: 16),

                  // Comments section — clients can view and post their own
                  // comments/replies (edit/delete limited to their own by
                  // the backend); studios manage overall gallery sharing.
                  MediaCommentsSection(
                    comments: likesComments.commentsForMedia(media.id),
                    currentUserId: likesComments.currentUserId,
                    isLoading: likesComments.isLoading,
                    onAddTopLevel: (text) =>
                        ref.read(mediaLikesCommentsProvider).addComment(
                              mediaId: media.id,
                              text: text,
                              parentId: null,
                            ),
                    onReply: (parentId, text) =>
                        ref.read(mediaLikesCommentsProvider).addComment(
                              mediaId: media.id,
                              text: text,
                              parentId: parentId,
                            ),
                    onEdit: (commentId, newText) =>
                        ref.read(mediaLikesCommentsProvider).editOwnComment(
                              commentId: commentId,
                              newText: newText,
                            ),
                    onDelete: (commentId) =>
                        ref.read(mediaLikesCommentsProvider).deleteOwnComment(
                              commentId: commentId,
                            ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
