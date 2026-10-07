import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/media_model.dart';
import '../../providers/client_gallery_provider.dart';
import '../../providers/media_likes_comments_provider.dart';
import '../media/image_viewer_screen.dart';
import '../media/video_player_screen.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/media/media_comments_section.dart';
import '../../widgets/media/media_thumb_badges.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../widgets/media/watermark_overlay.dart';
import '../../providers/auth_providers.dart' show apiClientProvider;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../core/theme/theme_context.dart';
import '../../widgets/common/grid_columns_button.dart';
import '../../widgets/media/media_thumb.dart';

/// Full photo-by-photo browser for a single album inside a studio's Shared
/// Gallery.
///
/// Fetches real media files from `GET /client/studios/{studio_id}/albums/{album_id}/media`
/// and displays them in a premium grid. Tapping a photo opens the image viewer;
/// tapping a video launches the video player.
class SharedAlbumPreviewScreen extends ConsumerStatefulWidget {
  final String studioId;
  final AlbumModel album;

  /// Whether the studio has enabled the watermark overlay for this gallery.
  final bool showWatermark;

  /// URL of the studio logo used as the watermark image.
  /// Falls back to [album.studioAvatarUrl] when not explicitly supplied.
  final String? watermarkUrl;

  const SharedAlbumPreviewScreen({
    super.key,
    required this.studioId,
    required this.album,
    this.showWatermark = false,
    this.watermarkUrl,
  });

  @override
  ConsumerState<SharedAlbumPreviewScreen> createState() =>
      _SharedAlbumPreviewScreenState();
}

class _SharedAlbumPreviewScreenState
    extends ConsumerState<SharedAlbumPreviewScreen> {
  List<MediaModel> _mediaList = [];
  bool _isLoading = true;

  /// Grid density chosen from the app-bar picker.
  int _columns = 3;
  String? _error;

  final Set<String> _selectedIds = {};

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final repo = ref.read(clientGalleryRepositoryProvider);
      final media =
          await repo.fetchSharedAlbumMedia(widget.studioId, widget.album.id);
      if (mounted) {
        setState(() {
          _mediaList = media;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// Studio logo to watermark with, or null if this gallery has the
  /// watermark off / no logo. Falls back to the studio avatar embedded in
  /// the album (`ConnectedAlbumRead.studio_avatar_url`).
  String? get _wmUrl {
    if (!widget.showWatermark) return null;
    final u = widget.watermarkUrl ?? widget.album.studioAvatarUrl;
    return (u == null || u.isEmpty) ? null : u;
  }

  void _openMedia(int index) {
    final media = _mediaList[index];
    final allIds = _mediaList.map((m) => m.id).toList();
    // Use the explicitly-supplied watermark URL; fall back to the studio's
    // avatar URL embedded in the album (set on ConnectedAlbumRead).
    final wUrl = widget.watermarkUrl ?? widget.album.studioAvatarUrl;

    if (media.type == MediaType.video) {
      Navigator.of(context).pushNamed(
        AppRoutes.videoPlayer,
        arguments: VideoPlayerArgs(
          mediaId: media.id,
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: _mediaList,
          readOnly: true,
          showWatermark: widget.showWatermark,
          watermarkUrl: wUrl,
        ),
      );
    } else {
      Navigator.of(context).pushNamed(
        AppRoutes.imageViewer,
        arguments: ImageViewerArgs(
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: _mediaList,
          readOnly: true,
          showWatermark: widget.showWatermark,
          watermarkUrl: wUrl,
        ),
      );
    }
  }

  /// Opens [media]'s comments in a bottom sheet. Same
  /// [MediaCommentsSection]/[mediaLikesCommentsProvider] wiring as
  /// `image_viewer_screen.dart` — the backend's like/comment endpoints
  /// accept any authenticated user with access to the media (studio
  /// owner, or a client viewing a shared album), not just the owner.
  void _openComments(MediaModel media) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: (Theme.of(context).brightness == Brightness.dark ? AppColors.darkBackground : AppColors.background),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                0,
              ),
              child: Consumer(builder: (context, ref, _) {
                final lc = ref.watch(mediaLikesCommentsProvider);
                if (!lc.hasFetchedComments(media.id)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    ref
                        .read(mediaLikesCommentsProvider)
                        .fetchComments(media.id);
                  });
                }
                return MediaCommentsSection(
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
                );
              }),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: widget.album.name, 
        showBack: true,
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: _selectedIds.length == _mediaList.length ? 'Deselect All' : 'Select All',
                  icon: Icon(_selectedIds.length == _mediaList.length
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded),
                  onPressed: () {
                    setState(() {
                      if (_selectedIds.length == _mediaList.length) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(_mediaList.map((m) => m.id));
                      }
                    });
                  },
                ),
              ]
            : [
                GridColumnsButton(
                  columns: _columns,
                  options: const [2, 3, 4, 6],
                  onChanged: (c) => setState(() => _columns = c),
                ),
              ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadMedia,
          child: _buildBody(),
        ),
      ),
      floatingActionButton: _isSelectionMode
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ids = _selectedIds.toList(growable: false);
                _clearSelection();
                if (ids.isEmpty) return;

                final apiClient = ref.read(apiClientProvider);
                const cache = MediaFileCache();
                const downloadService = DownloadServiceImpl();

                for (final id in ids) {
                  final m = _mediaList.firstWhere((x) => x.id == id,
                      orElse: () => _mediaList.first);
                  if (m.id != id) continue;

                  if (kIsWeb) {
                    final result =
                        await cache.bytesFor(m, watermarkUrl: _wmUrl);
                    if (result == null) continue;
                    if (!context.mounted) continue;
                    await downloadService.downloadBytes(
                      context: context,
                      bytes: result.bytes,
                      fileName: result.fileName,
                      mediaId: m.id,
                      apiClient: apiClient,
                      isClientUser: true,
                    );
                  } else {
                    final filePath =
                        await cache.localPathFor(m, watermarkUrl: _wmUrl);
                    if (filePath == null) continue;
                    if (!context.mounted) continue;
                    await downloadService.downloadOriginal(
                      context: context,
                      filePath: filePath,
                      mediaId: m.id,
                      apiClient: apiClient,
                      isClientUser: true,
                    );
                  }
                }
              },
              icon: Icon(Icons.download_rounded),
              label: Text('Download ${_selectedIds.length} items'),
              backgroundColor: AppColors.primary,
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading && _mediaList.isEmpty) {
      return Center(
          child: LoadingWidget(message: 'Loading gallery media…'));
    }

    if (_error != null && _mediaList.isEmpty) {
      final isNotFound = _error!.contains('404') ||
          _error!.contains('410') ||
          _error!.toLowerCase().contains('not found') ||
          _error!.toLowerCase().contains('revoked');
      final message = isNotFound
          ? 'This shared gallery is no longer available.'
          : 'Unable to load gallery photos. Check your connection and try again.';
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.7,
          alignment: Alignment.center,
          padding: EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InlineErrorBanner(message: message),
              SizedBox(height: AppSpacing.md),
              ElevatedButton.icon(
                onPressed: _loadMedia,
                icon: Icon(Icons.refresh_rounded),
                label: Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_mediaList.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.7,
          alignment: Alignment.center,
          padding: EdgeInsets.all(AppSpacing.xl),
          child: const EmptyStateCard(
            icon: Icons.photo_library_outlined,
            message: 'No photos or videos in this album yet.',
          ),
        ),
      );
    }

    return GridView.builder(
      physics:
          const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.all(AppSpacing.md),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 1.0,
      ),
      itemCount: _mediaList.length,
      itemBuilder: (context, index) {
        final media = _mediaList[index];
        // Seed once from the server-provided like_count/is_liked_by_me
        // (harmless no-op after the first build or a real toggle).
        ref.read(mediaLikesCommentsProvider).seedLikeState(media);
        final likeState =
            ref.watch(mediaLikesCommentsProvider).likeStateFor(media.id);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () => _toggleSelection(media.id),
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(media.id);
              return;
            }
            _openMedia(index);
          },
          child: Hero(
            tag: 'shared_media_${media.id}',
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: context.borderColor, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MediaThumb(
                      media: media, cacheWidth: _columns <= 2 ? 720 : 480),
                  if (_wmUrl != null)
                    WatermarkOverlay(
                      url: _wmUrl!,
                      heightFraction: 0.16,
                      minHeight: 12,
                      maxHeight: 40,
                    ),
                  if (media.type == MediaType.video)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  // Passive engagement summary (Task 21.13) — surfaces the
                  // server-seeded comment_count (Task 21.14-21.16) that the
                  // interactive chip below never showed a number for. Kept
                  // separate from the bottom-left chips since those are tap
                  // targets (toggle like / open comments) and MediaThumbBadges
                  // is deliberately non-interactive, auto-hiding at 0/0.
                  Positioned(
                    top: 4,
                    right: 4,
                    child: MediaThumbBadges(
                      likeCount: likeState.count,
                      commentCount: media.commentCount,
                      alignment: Alignment.topRight,
                    ),
                  ),
                  // Like + comment overlay — tap targets stop the tap from
                  // bubbling up to the tile's own onTap (which opens the
                  // fullscreen viewer instead).
                  if (_columns < 6)
                    Positioned(
                    left: 4,
                    bottom: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => ref
                              .read(mediaLikesCommentsProvider)
                              .toggleLike(media.id),
                          child: _TileOverlayChip(
                            icon: likeState.liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            iconColor: likeState.liked
                                ? Colors.redAccent
                                : Colors.white,
                            label: likeState.count > 0
                                ? '${likeState.count}'
                                : null,
                          ),
                        ),
                        SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _openComments(media),
                          child: const _TileOverlayChip(
                            icon: Icons.mode_comment_outlined,
                            iconColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_selectedIds.contains(media.id))
                    Positioned.fill(
                      child: Container(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        alignment: Alignment.topLeft,
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.check_circle_rounded,
                            color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small pill used for the like/comment overlay on each shared-album
/// grid tile — icon plus an optional count label.
class _TileOverlayChip extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String? label;

  const _TileOverlayChip(
      {required this.icon, required this.iconColor, this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: iconColor),
          if (label != null) ...[
            SizedBox(width: 3),
            Text(
              label!,
              style: TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
