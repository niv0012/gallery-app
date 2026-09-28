import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../models/user.dart' show AppUserRole;
import '../../providers/auth_providers.dart'
    show apiClientProvider, authStateProvider;
import '../../providers/media_provider.dart';
import '../../services/download_service.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../services/share_service.dart';
import '../../services/share_service_impl.dart';
import 'media_batch_workflows.dart';
import '../../providers/share_link_provider.dart';
import '../../providers/media_likes_comments_provider.dart';
import '../../widgets/common/delete_confirmation_dialog.dart';
import '../../widgets/media/download_complete_bottom_sheet.dart';
import '../../widgets/media/media_comments_section.dart';

/// Route arguments for [VideoPlayerScreen].
class VideoPlayerArgs {
  final String mediaId;
  final List<String>? mediaIds;
  final int initialIndex;
  final bool showWatermark;
  final bool allowDownload;
  final String? shareLinkId;
  final String? watermarkUrl;

  /// Pre-fetched media to display instead of resolving ids against
  /// `mediaProvider` — see [ImageViewerArgs.mediaItems] for why this is
  /// needed (client Shared Gallery media isn't in the owner-scoped
  /// provider). Order/content should match [mediaIds].
  final List<MediaModel>? mediaItems;

  /// Hides owner-only actions (Move, Copy, Rename, Delete) for media the
  /// current user doesn't own. See [ImageViewerArgs.readOnly].
  final bool readOnly;

  const VideoPlayerArgs({
    required this.mediaId,
    this.mediaIds,
    this.initialIndex = 0,
    this.showWatermark = false,
    this.allowDownload = true,
    this.shareLinkId,
    this.watermarkUrl,
    this.mediaItems,
    this.readOnly = false,
  });
}

/// Full-screen video playback with swipe, slideshow, and unified actions.
class VideoPlayerScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final List<String> mediaIds;
  final int initialIndex;
  final bool showWatermark;
  final bool allowDownload;
  final String? shareLinkId;
  final String? watermarkUrl;
  final List<MediaModel>? mediaItems;
  final bool readOnly;

  const VideoPlayerScreen({
    super.key,
    required this.mediaId,
    required this.mediaIds,
    required this.initialIndex,
    this.showWatermark = false,
    this.allowDownload = true,
    this.shareLinkId,
    this.watermarkUrl,
    this.mediaItems,
    this.readOnly = false,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  late final List<String> _mediaIds;
  late final PageController _pageController;
  late int _index;
  bool _chromeVisible = true;

  // Slideshow
  bool _slideshowPlaying = false;
  bool _isAdvancing = false;

  // Active controller
  VideoPlayerController? _activeController;

  // Video settings
  bool _isMuted = false;
  bool _isLooping = true;
  double _playbackSpeed = 1.0;

  // For toolbar/info panel
  bool _infoVisible = false;
  bool _isFullscreen = false;
  bool _isLandscape = false;

  // Services
  final ShareService _shareService = const ShareServiceImpl();
  final DownloadService _downloadService = const DownloadServiceImpl();
  final MediaFileCache _fileCache = const MediaFileCache();

  @override
  void initState() {
    super.initState();
    _mediaIds = widget.mediaIds.toSet().toList();
    _index = _mediaIds.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _mediaIds.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  Future<void> _setLandscape(bool landscape) async {
    if (kIsWeb) return;
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
    if (mounted) setState(() => _isLandscape = landscape);
  }

  Future<void> _toggleFullscreen() async {
    if (kIsWeb) return;
    final fullscreen = !_isFullscreen;
    await SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (fullscreen) {
      await _setLandscape(true);
    } else {
      await _setLandscape(false);
    }
    if (mounted) setState(() => _isFullscreen = fullscreen);
  }

  Future<void> _toggleOrientation() => _setLandscape(!_isLandscape);

  @override
  void dispose() {
    if (!kIsWeb) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    _pageController.dispose();
    if (_activeController != null) {
      _activeController!.removeListener(_videoListener);
    }
    super.dispose();
  }

  void _setChromeVisible(bool v) {
    if (_chromeVisible == v) return;
    setState(() => _chromeVisible = v);
  }

  /// Opens [media]'s comments in a bottom sheet — mirrors
  /// `image_viewer_screen.dart`'s `_openComments`, same
  /// `mediaLikesCommentsProvider`/`MediaCommentsSection` wiring.
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
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkBackground
                    : AppColors.background),
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

  void _onControllerChanged(VideoPlayerController? newController) {
    if (_activeController != null) {
      _activeController!.removeListener(_videoListener);
    }
    _activeController = newController;
    if (_activeController != null) {
      _activeController!.addListener(_videoListener);
      _activeController!.setVolume(_isMuted ? 0.0 : 1.0);
      _activeController!.setLooping(_isLooping);
      _activeController!.setPlaybackSpeed(_playbackSpeed);
      if (_slideshowPlaying) {
        _activeController!.play();
      }
    }
    setState(() {});
  }

  void _videoListener() {
    if (!mounted) return;

    if (_activeController != null && _activeController!.value.isInitialized) {
      final pos = _activeController!.value.position;
      final dur = _activeController!.value.duration;
      final isFinished = pos >= dur && dur > Duration.zero;

      if (isFinished && _slideshowPlaying) {
        _advanceToNext();
      }
    }
    setState(() {});
  }

  void _advanceToNext() {
    if (_isAdvancing) return;
    _isAdvancing = true;

    final mediaCount = _mediaIds.isEmpty ? 0 : _mediaIds.length;
    if (mediaCount <= 1) {
      _isAdvancing = false;
      return;
    }

    final next = (_index + 1) % mediaCount;
    _pageController
        .animateToPage(
      next,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      _isAdvancing = false;
    });
  }

  void _toggleSlideshow() {
    if (_slideshowPlaying) {
      setState(() => _slideshowPlaying = false);
      if (_activeController != null && _activeController!.value.isPlaying) {
        _activeController!.pause();
      }
      return;
    }

    setState(() => _slideshowPlaying = true);
    if (_activeController != null) {
      final pos = _activeController!.value.position;
      final dur = _activeController!.value.duration;
      if (pos >= dur && dur > Duration.zero) {
        _activeController!.seekTo(Duration.zero).then((_) {
          _activeController!.play();
        });
      } else if (!_activeController!.value.isPlaying) {
        _activeController!.play();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Maintain original ordering given by viewer args.
    final items = <MediaModel>[];
    final authToken = ref.read(apiClientProvider).authToken;
    if (widget.mediaItems != null) {
      // Pre-fetched media (e.g. client Shared Gallery) — never touches
      // mediaProvider, so it works for media the current user doesn't own.
      for (final id in _mediaIds) {
        for (final m in widget.mediaItems!) {
          if (m.id == id) {
            items.add(m);
            break;
          }
        }
      }
    } else {
      final c = ref.watch(mediaProvider);
      for (final id in _mediaIds) {
        for (final m in c.allMedia) {
          if (m.id == id) {
            items.add(m);
            break;
          }
        }
      }
    }

    if (items.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'This media no longer exists',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      );
    }

    final safeIndex = _index.clamp(0, items.length - 1);
    final current = items[safeIndex];

    Future<void> shareCurrent() async {
      if (kIsWeb) {
        final result = await _fileCache.bytesFor(current);
        if (result == null) return;
        if (!context.mounted) return;
        await _shareService.shareMediaBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
        );
        return;
      }
      final filePath = await _fileCache.localPathFor(current);
      if (filePath == null) return;
      if (!context.mounted) return;
      await _shareService.shareMedia(context: context, filePath: filePath);
    }

    Future<void> downloadCurrent() async {
      if (!widget.allowDownload) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Downloads are disabled for this shared gallery.')),
        );
        return;
      }
      bool saved = false;
      String? filePath;
      final apiClient = ref.read(apiClientProvider);
      final isClientUser =
          ref.read(authStateProvider).user?.role == AppUserRole.client;

      if (kIsWeb) {
        final result = await _fileCache.bytesFor(current);
        if (result == null) return;
        if (!context.mounted) return;
        saved = await _downloadService.downloadBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
          mediaId: current.id,
          apiClient: apiClient,
          isClientUser: isClientUser,
        );
      } else {
        filePath = await _fileCache.localPathFor(current);
        if (filePath == null) return;
        if (!context.mounted) return;
        saved = await _downloadService.downloadOriginal(
          context: context,
          filePath: filePath,
          mediaId: current.id,
          apiClient: apiClient,
          isClientUser: isClientUser,
        );
      }
      if (widget.shareLinkId != null) {
        // Fire-and-forget: real /public/share-links/{token}/download call
        // instead of the old local-only incrementDownloads.
        ref
            .read(publicGalleryControllerProvider(
                    PublicGalleryTarget(token: widget.shareLinkId!))
                .notifier)
            .recordDownload(mediaId: current.id);
      }
      if (saved && context.mounted) {
        await DownloadCompleteBottomSheet.show(
          context: context,
          fileName: current.fileName,
          size: current.size,
          thumbnailPath: filePath,
          filePath: filePath,
          media: current,
        );
      }
    }

    /// Saves to the OS photo/video gallery on mobile, mirroring
    /// [downloadCurrent]'s web-vs-device split. On web there's no gallery
    /// and no filesystem path to hand `gal`, so it falls back to the same
    /// in-memory "save as" flow used there. Permission prompts and the
    /// success/failure snackbar live inside [DownloadService.saveToGallery].
    Future<void> saveCurrentToGallery() async {
      if (!widget.allowDownload) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Saving is disabled for this shared gallery.')),
        );
        return;
      }
      bool saved = false;
      String? filePath;
      final apiClient = ref.read(apiClientProvider);
      final isClientUser =
          ref.read(authStateProvider).user?.role == AppUserRole.client;

      if (kIsWeb) {
        final result = await _fileCache.bytesFor(current);
        if (result == null) return;
        if (!context.mounted) return;
        saved = await _downloadService.downloadBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
          mediaId: current.id,
          apiClient: apiClient,
          isClientUser: isClientUser,
        );
      } else {
        filePath = await _fileCache.localPathFor(current);
        if (filePath == null) return;
        if (!context.mounted) return;
        saved = await _downloadService.saveToGallery(
          context: context,
          filePath: filePath,
          mediaId: current.id,
          apiClient: apiClient,
          isClientUser: isClientUser,
        );
      }
      if (widget.shareLinkId != null) {
        // Fire-and-forget: real /public/share-links/{token}/download call
        // instead of the old local-only incrementDownloads.
        ref
            .read(publicGalleryControllerProvider(
                    PublicGalleryTarget(token: widget.shareLinkId!))
                .notifier)
            .recordDownload(mediaId: current.id);
      }
      if (saved && context.mounted) {
        await DownloadCompleteBottomSheet.show(
          context: context,
          fileName: current.fileName,
          size: current.size,
          thumbnailPath: filePath,
          filePath: filePath,
          media: current,
        );
      }
    }

    Future<void> confirmDelete(MediaModel m) async {
      final confirmed = await showDeleteConfirmationDialog(
        context: context,
        title: 'Delete item?',
        message:
            'This will remove "${m.fileName}" from your library. This action cannot be undone.',
      );
      if (!context.mounted) return;
      if (!confirmed) return;

      final controller = ref.read(mediaProvider);

      // Temporarily select this id for the existing batchDelete flow.
      final prev = controller.selectedIds.toSet();
      controller.deselectAll();
      controller.toggleSelected(m.id);
      await controller.batchDelete();

      // Restore selection.
      controller.deselectAll();
      for (final id in prev) {
        controller.toggleSelected(id);
      }

      if (context.mounted) Navigator.of(context).pop();
    }

    Future<void> renameCurrent() async {
      final controller = ref.read(mediaProvider);
      final prev = controller.selectedIds.toSet();

      final nameController = TextEditingController(text: current.fileName);

      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Rename media'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
              hintText: 'Enter new file name',
            ),
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

      if (newName == null) return;

      await controller.renameMediaById(
          mediaId: current.id, newFileName: newName);

      // Restore selection.
      controller.deselectAll();
      for (final id in prev) {
        controller.toggleSelected(id);
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: items.length,
              onPageChanged: (i) {
                setState(() {
                  _index = i;
                  _onControllerChanged(null);
                });
                _setChromeVisible(false);
              },
              itemBuilder: (context, i) {
                final m = items[i];
                final isNearby = (i - _index).abs() <= 1;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setChromeVisible(!_chromeVisible),
                  child: Center(
                    child: Hero(
                      tag: 'hero-media-${m.id}',
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: _VideoPlayerItem(
                              media: m,
                              isActive: i == _index,
                              isNearby: isNearby,
                              authToken: authToken,
                              onControllerInitialized: _onControllerChanged,
                            ),
                          ),
                          if (widget.showWatermark && widget.watermarkUrl != null && widget.watermarkUrl!.isNotEmpty)
                            Positioned(
                              right: 16,
                              bottom: 16,
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0.7,
                                  child: Image.network(
                                    widget.watermarkUrl!,
                                    height: 48,
                                    fit: BoxFit.contain,
                                    errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !_chromeVisible,
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                      child: Row(
                        children: [
                          _RoundIconButton(
                            icon: Icons.arrow_back_rounded,
                            onTap: () {
                              _slideshowPlaying = false;
                              _activeController?.pause();
                              if (context.mounted) Navigator.of(context).pop();
                            },
                          ),
                          const Spacer(),
                          Text(
                            '${safeIndex + 1} / ${items.length}',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                          SizedBox(width: AppSpacing.sm),
                          _RoundIconButton(
                            icon: current.isFavorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            iconColor: current.isFavorite
                                ? AppColors.accent
                                : Colors.white,
                            onTap: () => ref
                                .read(mediaProvider)
                                .toggleFavorite(current.id),
                          ),
                        ],
                      ),
                    ),
                    if (_chromeVisible) const Spacer(),
                    if (_infoVisible && _chromeVisible)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                            AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                        child: _InfoPanel(media: current),
                      ),
                    Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.48),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_activeController != null &&
                                _activeController!.value.isInitialized) ...[
                              VideoProgressIndicator(
                                _activeController!,
                                allowScrubbing: true,
                                padding: EdgeInsets.symmetric(
                                    vertical: AppSpacing.sm),
                                colors: const VideoProgressColors(
                                  playedColor: AppColors.primary,
                                  bufferedColor: Colors.white24,
                                  backgroundColor: Colors.white10,
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      MediaFormatUtils.formatDuration(
                                          _activeController!.value.position),
                                      style: TextStyle(
                                          color: Colors.white70, fontSize: 11),
                                    ),
                                    Builder(builder: (context) {
                                      final pos =
                                          _activeController!.value.position;
                                      final dur =
                                          _activeController!.value.duration;
                                      final isFinished =
                                          pos >= dur && dur > Duration.zero;
                                      final icon = isFinished
                                          ? Icons.replay_rounded
                                          : (_activeController!.value.isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded);

                                      return IconButton(
                                        iconSize: 32,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: Icon(
                                          icon,
                                          color: Colors.white,
                                        ),
                                        onPressed: () {
                                          if (isFinished) {
                                            _activeController!
                                                .seekTo(Duration.zero)
                                                .then((_) {
                                              _activeController!.play();
                                            });
                                          } else {
                                            if (_activeController!
                                                .value.isPlaying) {
                                              _activeController!.pause();
                                            } else {
                                              _activeController!.play();
                                            }
                                          }
                                          setState(() {});
                                        },
                                      );
                                    }),
                                    Builder(builder: (context) {
                                      final pos =
                                          _activeController!.value.position;
                                      final dur =
                                          _activeController!.value.duration;
                                      final remaining = dur - pos;
                                      final displayRemaining =
                                          remaining.isNegative
                                              ? Duration.zero
                                              : remaining;

                                      return Text(
                                        '-${MediaFormatUtils.formatDuration(displayRemaining)}',
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11),
                                      );
                                    }),
                                  ],
                                ),
                              ),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    current.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  tooltip:
                                      _infoVisible ? 'Hide info' : 'Show info',
                                  onPressed: () => setState(
                                      () => _infoVisible = !_infoVisible),
                                  icon: Icon(
                                    _infoVisible
                                        ? Icons.info_rounded
                                        : Icons.info_outline_rounded,
                                    color: Colors.white,
                                  ),
                                )
                              ],
                            ),
                            SizedBox(height: AppSpacing.sm),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.sm,
                              alignment: WrapAlignment.center,
                              children: [
                                if (widget.allowDownload)
                                  _ActionChip(
                                    icon: Icons.ios_share_rounded,
                                    label: 'Share',
                                    onTap: shareCurrent,
                                  ),
                                if (widget.allowDownload)
                                  _ActionChip(
                                    icon: Icons.download_rounded,
                                    label: 'Download',
                                    onTap: downloadCurrent,
                                  ),
                                if (widget.allowDownload)
                                  _ActionChip(
                                    icon: Icons.add_photo_alternate_rounded,
                                    label: 'Save to Gallery',
                                    onTap: saveCurrentToGallery,
                                  ),
                                if (widget.shareLinkId == null)
                                  Consumer(builder: (context, ref, _) {
                                    final lc =
                                        ref.watch(mediaLikesCommentsProvider);
                                    lc.seedLikeState(current);
                                    final likeState =
                                        lc.likeStateFor(current.id);
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _ActionChip(
                                          icon: likeState.liked
                                              ? Icons.favorite_rounded
                                              : Icons.favorite_border_rounded,
                                          iconColor: likeState.liked
                                              ? AppColors.accent
                                              : null,
                                          label: likeState.count > 0
                                              ? '${likeState.count}'
                                              : 'Like',
                                          onTap: () =>
                                              lc.toggleLike(current.id),
                                        ),
                                        SizedBox(width: AppSpacing.sm),
                                        _ActionChip(
                                          icon: Icons.mode_comment_outlined,
                                          label: 'Comments',
                                          onTap: () => _openComments(current),
                                        ),
                                      ],
                                    );
                                  }),
                                if (!widget.readOnly) ...[
                                  _ActionChip(
                                    icon: Icons.drive_file_move_rounded,
                                    label: 'Move',
                                    onTap: () => MediaBatchWorkflows.openMove(
                                      context: context,
                                      mediaIds: [current.id],
                                    ),
                                  ),
                                  _ActionChip(
                                    icon: Icons.copy_all_rounded,
                                    label: 'Copy',
                                    onTap: () => MediaBatchWorkflows.openCopy(
                                      context: context,
                                      mediaIds: [current.id],
                                    ),
                                  ),
                                  _ActionChip(
                                    icon:
                                        Icons.drive_file_rename_outline_rounded,
                                    label: 'Rename',
                                    onTap: renameCurrent,
                                  ),
                                  _ActionChip(
                                    icon: Icons.delete_outline_rounded,
                                    label: 'Delete',
                                    iconColor: AppColors.error,
                                    onTap: () => confirmDelete(current),
                                  ),
                                ],
                                _ActionChip(
                                  icon: _slideshowPlaying
                                      ? Icons.pause_circle_filled_rounded
                                      : Icons.play_circle_filled_rounded,
                                  label: 'Slideshow',
                                  onTap: _toggleSlideshow,
                                ),
                                _ActionChip(
                                  icon: _isMuted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                  label: _isMuted ? 'Muted' : 'Mute',
                                  iconColor: _isMuted
                                      ? AppColors.accent
                                      : Colors.white,
                                  onTap: () {
                                    setState(() {
                                      _isMuted = !_isMuted;
                                      _activeController
                                          ?.setVolume(_isMuted ? 0.0 : 1.0);
                                    });
                                  },
                                ),
                                _ActionChip(
                                  icon: _isLooping
                                      ? Icons.repeat_one_rounded
                                      : Icons.arrow_right_alt_rounded,
                                  label: _isLooping ? 'Loop' : 'No Loop',
                                  iconColor: _isLooping
                                      ? AppColors.accent
                                      : Colors.white,
                                  onTap: () {
                                    setState(() {
                                      _isLooping = !_isLooping;
                                      _activeController?.setLooping(_isLooping);
                                    });
                                  },
                                ),
                                _ActionChip(
                                  icon: _isLandscape
                                      ? Icons.stay_current_portrait_rounded
                                      : Icons.screen_rotation_rounded,
                                  label: _isLandscape ? 'Portrait' : 'Rotate',
                                  onTap: _toggleOrientation,
                                ),
                                _ActionChip(
                                  icon: _isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  label: _isFullscreen
                                      ? 'Exit Full screen'
                                      : 'Full screen',
                                  onTap: _toggleFullscreen,
                                ),
                                _ActionChip(
                                  icon: Icons.speed_rounded,
                                  label: '${_playbackSpeed}x',
                                  onTap: () {
                                    setState(() {
                                      if (_playbackSpeed == 0.5) {
                                        _playbackSpeed = 1.0;
                                      } else if (_playbackSpeed == 1.0) {
                                        _playbackSpeed = 1.5;
                                      } else if (_playbackSpeed == 1.5) {
                                        _playbackSpeed = 2.0;
                                      } else {
                                        _playbackSpeed = 0.5;
                                      }
                                      _activeController
                                          ?.setPlaybackSpeed(_playbackSpeed);
                                    });
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoPlayerItem extends StatefulWidget {
  final MediaModel media;
  final bool isActive;
  final bool isNearby;
  final String? authToken;
  final ValueChanged<VideoPlayerController?> onControllerInitialized;

  const _VideoPlayerItem({
    required this.media,
    required this.isActive,
    required this.isNearby,
    this.authToken,
    required this.onControllerInitialized,
  });

  @override
  State<_VideoPlayerItem> createState() => _VideoPlayerItemState();
}

class _VideoPlayerItemState extends State<_VideoPlayerItem> {
  VideoPlayerController? _controller;
  bool _initializing = false;
  bool _initFailed = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    if (widget.isNearby) {
      _init();
    }
  }

  @override
  void didUpdateWidget(covariant _VideoPlayerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.displayPath != widget.media.displayPath) {
      if (widget.isNearby) {
        _init();
      } else {
        _disposeController();
      }
    } else if (widget.isNearby != oldWidget.isNearby) {
      if (widget.isNearby) {
        _init();
      } else {
        _disposeController();
      }
    } else if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        if (_controller != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onControllerInitialized(_controller);
            }
          });
        } else if (widget.isNearby) {
          _init();
        }
      } else {
        _controller?.pause();
      }
    }
  }

  void _disposeController() {
    if (_controller != null) {
      _controller!.dispose();
      _controller = null;
    }
    setState(() {
      _initializing = false;
      _initFailed = false;
      _initError = null;
    });
  }

  Future<void> _init() async {
    if (_initializing) return;

    if (_controller != null) {
      _controller!.dispose();
      _controller = null;
    }

    setState(() {
      _initializing = true;
      _initFailed = false;
      _initError = null;
    });

    final sources = <({String path, bool network})>[];
    final localPath = widget.media.filePath;
    final remotePath = widget.media.remoteUrl;

    // Prefer a usable local file, but always retry the server copy when the
    // cached/cut file exists and is no longer playable.
    if (!kIsWeb && localPath.isNotEmpty && File(localPath).existsSync()) {
      sources.add((path: localPath, network: false));
    }
    if (remotePath != null &&
        remotePath.isNotEmpty &&
        (remotePath.startsWith('http://') ||
            remotePath.startsWith('https://'))) {
      sources.add((path: remotePath, network: true));
    }
    if (sources.isEmpty && !kIsWeb && localPath.isNotEmpty) {
      sources.add((path: localPath, network: false));
    }
    if (sources.isEmpty && kIsWeb && remotePath != null) {
      sources.add((path: remotePath, network: true));
    }

    Object? lastError;
    for (final source in sources) {
      final controller = source.network
          ? VideoPlayerController.networkUrl(
              Uri.parse(source.path),
              formatHint: source.path.toLowerCase().contains('.mkv')
                  ? VideoFormat.other
                  : null,
              httpHeaders: source.network &&
                      widget.authToken != null &&
                      widget.authToken!.isNotEmpty
                  ? {'Authorization': 'Bearer ${widget.authToken}'}
                  : const {},
            )
          : VideoPlayerController.file(File(source.path));
      try {
        await controller.initialize();
        if (!mounted || !widget.isNearby) {
          controller.dispose();
          return;
        }
        setState(() {
          _controller = controller;
          _initializing = false;
        });
        if (widget.isActive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onControllerInitialized(_controller);
          });
        }
        return;
      } catch (e) {
        lastError = e;
        debugPrint(
          'Error initializing video source (${source.network ? 'network' : 'local'}): $e',
        );
        controller.dispose();
      }
    }

    if (!mounted) return;
    setState(() {
      _initializing = false;
      _initFailed = true;
      _initError = lastError?.toString();
    });
    if (lastError != null) {
      debugPrint('Video playback failed for ${widget.media.id}: $lastError');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isNearby) {
      return SizedBox.shrink();
    }

    if (_initializing) {
      return Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_initFailed || _controller == null) {
      return _NoVideoPlaceholder(media: widget.media, error: _initError);
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _controller!.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(_controller!),
            if (_controller!.value.isBuffering)
              const CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _NoVideoPlaceholder extends StatelessWidget {
  final MediaModel media;
  final String? error;

  const _NoVideoPlaceholder({required this.media, this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(media.gradientArgb.first),
            Color(media.gradientArgb[1])
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_off_rounded,
              color: Colors.white.withValues(alpha: 0.92), size: 48),
          SizedBox(height: AppSpacing.sm),
          Text(
            error == null
                ? 'Video file not available on this device'
                : 'Unable to play this video',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontWeight: FontWeight.w700,
                fontSize: 12.5),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 12, right: 12),
              child: Text(
                error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 9,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor ?? Colors.white),
        onPressed: onTap,
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final MediaModel media;
  const _InfoPanel({required this.media});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _infoRow('Size', MediaFormatUtils.formatFileSize(media.size)),
          _infoRow('Resolution',
              MediaFormatUtils.formatResolution(media.width, media.height)),
          _infoRow('Created', MediaFormatUtils.formatDate(media.createdAt)),
          _infoRow('Path', media.displayPath),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label: ',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: iconColor ?? Colors.white),
      label: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      onPressed: onTap,
      // A translucent *white* pill washes out to invisible over bright
      // or light-colored video frames (the white label text disappears
      // into it). A dark scrim behind white text/icons keeps them
      // legible regardless of what's playing underneath.
      backgroundColor: Colors.black.withValues(alpha: 0.45),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    );
  }
}
