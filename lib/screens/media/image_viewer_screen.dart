import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../services/share_service.dart';
import '../../services/share_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../core/routes/app_routes.dart';
import '../../widgets/media/edited_image.dart';
import '../../widgets/media/media_comments_section.dart';
import 'media_batch_workflows.dart';
import '../../providers/share_link_provider.dart';
import '../../providers/media_likes_comments_provider.dart';
import '../../widgets/media/media_like_button.dart';

const _viewerFileCache = MediaFileCache();

/// Route arguments for [ImageViewerScreen].
class ImageViewerArgs {
  final List<String> mediaIds;
  final int initialIndex;
  final bool showWatermark;
  final bool allowDownload;
  final String? shareLinkId;
  final String? watermarkUrl;

  /// Pre-fetched media to display instead of resolving [mediaIds] against
  /// `mediaProvider`. Required for any caller whose media isn't in the
  /// current user's own owner-scoped `mediaProvider` state — e.g. the
  /// client Shared Gallery, where the media belongs to a studio the
  /// client doesn't own and `mediaProvider` would either be empty or
  /// 403 if loaded. Order/content of [mediaItems] should match
  /// [mediaIds]; when provided it takes priority over the provider
  /// lookup.
  final List<MediaModel>? mediaItems;

  /// When true, hides owner-only actions (Move, Copy, Rename, Delete,
  /// Edit) that mutate media the current user doesn't own. Share-link
  /// viewing already restricts via [allowDownload]/[showWatermark] but
  /// never actually hid these buttons — [readOnly] is the explicit,
  /// correct gate for any read-only viewing context.
  final bool readOnly;

  const ImageViewerArgs({
    required this.mediaIds,
    required this.initialIndex,
    this.showWatermark = false,
    this.allowDownload = true,
    this.shareLinkId,
    this.watermarkUrl,
    this.mediaItems,
    this.readOnly = false,
  });
}

/// Full-screen, swipeable image viewer.
///
/// - Preserves zoom per-image (scale + translation)
/// - Double-tap zoom toggle: fit ↔ 2x ↔ 3x
/// - Tap toggles chrome visibility (single tap)
/// - Includes slideshow mode
/// - Preserves hero tags via `media-<id>`
class ImageViewerScreen extends ConsumerStatefulWidget {
  final List<String> mediaIds;
  final int initialIndex;
  final bool showWatermark;
  final bool allowDownload;
  final String? shareLinkId;
  final String? watermarkUrl;
  final List<MediaModel>? mediaItems;
  final bool readOnly;

  const ImageViewerScreen({
    super.key,
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
  ConsumerState<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends ConsumerState<ImageViewerScreen> {
  late final List<String> _mediaIds;
  late final PageController _pageController;
  late int _index;
  bool _chromeVisible = true;

  // Slideshow
  Timer? _slideshowTimer;
  bool _slideshowPlaying = false;

  // Per-image zoom state isolation.
  final Map<String, double> _scaleById = {};
  final Map<String, Offset> _offsetById = {};
  final Map<String, TransformationController> _transformById = {};

  // For toolbar/info panel
  bool _infoVisible = false;

  // Services (existing implementations)
  final ShareService _shareService = const ShareServiceImpl();
  final DownloadService _downloadService = const DownloadServiceImpl();

  /// Studio logo to watermark with, or null when this gallery has the
  /// watermark turned off / no logo. Used for the on-screen overlay AND
  /// for the copy that's downloaded/shared.
  String? get _watermarkUrl {
    if (!widget.showWatermark) return null;
    final u = widget.watermarkUrl;
    return (u == null || u.isEmpty) ? null : u;
  }

  @override
  void initState() {
    super.initState();
    _mediaIds = widget.mediaIds.toSet().toList();
    _index = _mediaIds.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _mediaIds.length - 1);
    _pageController = PageController(initialPage: _index);

    // Photos opened from face-search results (or any pre-fetched list)
    // aren't in the main paged media list, so favorite / rename / move /
    // copy / edit / delete had nothing to act on. Register them with the
    // provider so every action works for them too. Skipped for
    // read-only contexts (shared galleries) that don't own the media.
    final prefetched = widget.mediaItems;
    if (prefetched != null && !widget.readOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(mediaProvider).adoptMedia(prefetched);
      });
    }
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _pageController.dispose();
    for (final c in _transformById.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setChromeVisible(bool v) {
    if (_chromeVisible == v) return;
    setState(() => _chromeVisible = v);
  }

  /// Opens [media]'s comments in a bottom sheet. Reuses the same
  /// [MediaCommentsSection] widget and [mediaLikesCommentsProvider]
  /// wiring `media_details_screen.dart` already uses for the studio
  /// side — the backend's like/comment endpoints now accept any
  /// authenticated user with access to the media (studio owner, or a
  /// client viewing a connected/shared album), not just the owner.
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

  void _toggleSlideshow() {
    if (_slideshowPlaying) {
      _slideshowTimer?.cancel();
      _slideshowTimer = null;
      setState(() => _slideshowPlaying = false);
      return;
    }

    setState(() => _slideshowPlaying = true);

    _slideshowTimer?.cancel();
    _slideshowTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_slideshowPlaying) return;
      final mediaCount = _mediaIds.isEmpty ? 0 : _mediaIds.length;
      if (mediaCount <= 1) return;

      final next = (_index + 1) % mediaCount;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  double _currentScale(String id) => _scaleById[id] ?? 1.0;

  void _ensureTransformFor(String id) {
    if (_transformById.containsKey(id)) return;
    final t = TransformationController();
    final s = _currentScale(id);
    final o = _offsetById[id] ?? Offset.zero;
    t.value = Matrix4.identity()
      ..translate(o.dx, o.dy)
      ..scale(s);
    _transformById[id] = t;
  }

  void _applyCurrentTransformToState(String id) {
    final c = _transformById[id];
    if (c == null) return;

    final m = c.value;
    final s = m.getMaxScaleOnAxis();
    // Translation components.
    final o = Offset(m.storage[12], m.storage[13]);

    _scaleById[id] = s.clamp(1.0, 3.0);
    _offsetById[id] = o;
  }

  void _setTransformForState(String id) {
    final c = _transformById[id];
    if (c == null) return;

    final s = _currentScale(id).clamp(1.0, 3.0);
    final o = _offsetById[id] ?? Offset.zero;
    c.value = Matrix4.identity()
      ..translate(o.dx, o.dy)
      ..scale(s);
  }

  void _doubleTapZoom(String id) {
    _ensureTransformFor(id);
    final currentScale = _currentScale(id);

    // 1.0 -> 2.0 -> 3.0 -> 1.0
    final nextScale = currentScale < 1.5
        ? 2.0
        : currentScale < 2.5
            ? 3.0
            : 1.0;

    if (nextScale == 1.0) {
      _scaleById[id] = 1.0;
      _offsetById[id] = Offset.zero;
    } else {
      _scaleById[id] = nextScale;
      // Keep current offset to avoid jump; pinch can adjust.
      _offsetById[id] = _offsetById[id] ?? Offset.zero;
    }

    setState(() {
      _setTransformForState(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Maintain original ordering given by viewer args.
    final items = <MediaModel>[];
    if (widget.mediaItems != null) {
      // Pre-fetched media (client Shared Gallery, face-search results).
      // For owner views prefer the provider's copy so favorite / rename /
      // move / edit changes show up immediately; fall back to the
      // pre-fetched snapshot until it has been adopted.
      final live = widget.readOnly ? null : ref.watch(mediaProvider);
      final gone = live?.deletedIds ?? const <String>{};
      for (final id in _mediaIds) {
        if (gone.contains(id)) continue;
        final fresh = live?.byId(id);
        if (fresh != null) {
          items.add(fresh);
          continue;
        }
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
      final isNetwork = current.isDisplayPathNetwork;
      if (isNetwork && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 10),
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Preparing media…'),
              ],
            ),
          ),
        );
      }

      if (kIsWeb) {
        final result = await _viewerFileCache.bytesFor(
            current,
            watermarkUrl: _watermarkUrl);
        if (isNetwork && context.mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        if (result == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text(
                      "Couldn't share media. Check your connection and try again.")),
            );
          }
          return;
        }
        if (!context.mounted) return;
        await _shareService.shareMediaBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
        );
        return;
      }

      final filePath = await _viewerFileCache.localPathFor(
          current,
          watermarkUrl: _watermarkUrl);
      if (isNetwork && context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      if (filePath == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    "Couldn't share media. Check your connection and try again.")),
          );
        }
        return;
      }
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

      final isNetwork = current.isDisplayPathNetwork;
      if (isNetwork && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 10),
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Preparing media…'),
              ],
            ),
          ),
        );
      }

      if (kIsWeb) {
        final result = await _viewerFileCache.bytesFor(
            current,
            watermarkUrl: _watermarkUrl);
        if (isNetwork && context.mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        if (result == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text(
                      "Couldn't download media. Check your connection and try again.")),
            );
          }
          return;
        }
        if (!context.mounted) return;
        await _downloadService.downloadBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
          mediaId: current.id,
          apiClient: ref.read(apiClientProvider),
          isClientUser:
              ref.read(authStateProvider).user?.role == AppUserRole.client,
        );
      } else {
        final filePath = await _viewerFileCache.localPathFor(
          current,
          watermarkUrl: _watermarkUrl);
        if (isNetwork && context.mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        if (filePath == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text(
                      "Couldn't download media. Check your connection and try again.")),
            );
          }
          return;
        }
        if (!context.mounted) return;
        await _downloadService.downloadOriginal(
          context: context,
          filePath: filePath,
          mediaId: current.id,
          apiClient: ref.read(apiClientProvider),
          isClientUser:
              ref.read(authStateProvider).user?.role == AppUserRole.client,
        );
      }

      if (widget.shareLinkId != null) {
        // Fire-and-forget: records the download against the real
        // /public/share-links/{token}/download endpoint (analytics
        // counter + Download History row), same as the old local
        // incrementDownloads this replaces, just backed by the server
        // instead of on-device storage.
        ref
            .read(publicGalleryControllerProvider(PublicGalleryTarget(token: widget.shareLinkId!)).notifier)
            .recordDownload(mediaId: current.id);
      }
    }

    Future<void> confirmDelete(MediaModel m) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete media?'),
          content: Text('This removes the media from your library.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final controller = ref.read(mediaProvider);

      // Temporarily select this id for the existing batchDelete flow.
      final prev = controller.selectedIds.toSet();
      controller.deselectAll();
      controller.toggleSelected(m.id);
      await controller.batchDelete();

      // Restore selection set if the controller still lives.
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

      final before = controller.byId(current.id)?.fileName ?? current.fileName;
      try {
        final updated = await controller.renameMediaById(
            mediaId: current.id, newFileName: newName, fallbackMedia: current);
        if (updated != null && context.mounted) {
          setState(() {
            items[_index] = updated;
          });
        }
        
        final after = controller.byId(current.id)?.fileName;
        if (context.mounted && after == before && newName.trim() != before && updated == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    "Couldn't rename — the name is empty, invalid, or already used in this album.")),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't rename this file. Try again.")),
          );
        }
      }

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
                _applyCurrentTransformToState(items[_index].id);
                setState(() => _index = i);
                _setChromeVisible(false);
                // Pause slideshow chrome; keep playing.
              },
              itemBuilder: (context, i) {
                final m = items[i];

                _ensureTransformFor(m.id);
                final t = _transformById[m.id]!;

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setChromeVisible(!_chromeVisible),
                  onDoubleTap: () {
                    // Cancel chrome toggle on double-tap automatically.
                    _doubleTapZoom(m.id);
                  },
                  child: Center(
                    child: InteractiveViewer(
                      transformationController: t,
                      minScale: 1,
                      maxScale: 3,
                      panEnabled: true,
                      scaleEnabled: true,
                      trackpadScrollCausesScale: true,
                      // Improved pinch: reset offset when at fit.
                      onInteractionEnd: (_) =>
                          _applyCurrentTransformToState(m.id),
                      child: Hero(
                        tag: 'hero-media-${m.id}',
                        // Ensure hero transitions use image itself.
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Center(
                              child: _MediaPreview(
                                media: m,
                                watermarkUrl: _watermarkUrl,
                              ),
                            ),
                          ],
                        ),
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
                              _slideshowTimer?.cancel();
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
                            onTap: () {
                              ref
                                  .read(mediaProvider)
                                  .toggleFavorite(current.id, fallbackMedia: current);
                              if (widget.mediaItems != null && context.mounted) {
                                setState(() {
                                  items[_index] = current.copyWith(isFavorite: !current.isFavorite);
                                });
                              }
                            },
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
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: Container(
                            padding: EdgeInsets.fromLTRB(AppSpacing.md,
                                AppSpacing.sm, AppSpacing.md, AppSpacing.md),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.15)),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            current.fileName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            MediaFormatUtils.formatDate(
                                                current.createdAt),
                                            style: TextStyle(
                                              color: Colors.white
                                                  .withValues(alpha: 0.5),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _infoVisible
                                          ? 'Hide info'
                                          : 'Show info',
                                      onPressed: () => setState(
                                          () => _infoVisible = !_infoVisible),
                                      icon: Icon(
                                        _infoVisible
                                            ? Icons.info_rounded
                                            : Icons.info_outline_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    )
                                  ],
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Wrap(
                                  spacing: AppSpacing.xs + 2,
                                  runSpacing: AppSpacing.xs + 2,
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
                                        label: 'Save',
                                        onTap: downloadCurrent,
                                      ),
                                    // Allow likes/comments regardless of shareLinkId.
                                    // The user must be authenticated to like/comment, but we handle
                                    // that by checking if they have an active session (which the
                                    // backend requires for /like and /comments).
                                    Consumer(builder: (context, ref, _) {
                                      final lc =
                                          ref.watch(mediaLikesCommentsProvider);
                                      lc.seedLikeState(current);
                                      final likeState =
                                          lc.likeStateFor(current.id);
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          MediaLikeButton(
                                            liked: likeState.liked,
                                            likeCount: likeState.count,
                                            onToggle: () {
                                              final auth =
                                                  ref.read(authStateProvider);
                                              if (auth.user == null) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(const SnackBar(
                                                        content: Text(
                                                            'Please log in or create an account to like photos.')));
                                                return;
                                              }
                                              lc.toggleLike(current.id);
                                            },
                                          ),
                                          SizedBox(width: AppSpacing.sm),
                                          _ActionChip(
                                            icon: Icons
                                                .chat_bubble_outline_rounded,
                                            label: current.commentCount > 0
                                                ? '${current.commentCount}'
                                                : 'Comment',
                                            onTap: () {
                                              final auth =
                                                  ref.read(authStateProvider);
                                              if (auth.user == null) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(const SnackBar(
                                                        content: Text(
                                                            'Please log in or create an account to comment.')));
                                                return;
                                              }
                                              _openComments(current);
                                            },
                                          ),
                                        ],
                                      );
                                    }),
                                    if (!widget.readOnly) ...[
                                      _ActionChip(
                                        icon: Icons.drive_file_move_rounded,
                                        label: 'Move',
                                        onTap: () =>
                                            MediaBatchWorkflows.openMove(
                                          context: context,
                                          mediaIds: [current.id],
                                        ),
                                      ),
                                      _ActionChip(
                                        icon: Icons.copy_all_rounded,
                                        label: 'Copy',
                                        onTap: () =>
                                            MediaBatchWorkflows.openCopy(
                                          context: context,
                                          mediaIds: [current.id],
                                        ),
                                      ),
                                      if (current.type == MediaType.photo)
                                        _ActionChip(
                                          icon: Icons.tune_rounded,
                                          label: 'Edit',
                                          onTap: () {
                                            Navigator.of(context).pushNamed(
                                              AppRoutes.photoEditor,
                                              arguments: PhotoEditorArgs(
                                                  media: current),
                                            );
                                          },
                                        ),
                                      _ActionChip(
                                        icon: Icons
                                            .drive_file_rename_outline_rounded,
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
                                      label: _slideshowPlaying
                                          ? 'Pause'
                                          : 'Slideshow',
                                      onTap: _toggleSlideshow,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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

class _MediaPreview extends StatelessWidget {
  final MediaModel media;
  final String? watermarkUrl;
  const _MediaPreview({required this.media, this.watermarkUrl});

  @override
  Widget build(BuildContext context) {
    final path = media.displayPath;
    final isNetwork = media.isDisplayPathNetwork;
    final file = (!isNetwork && path.isNotEmpty) ? File(path) : null;
    final hasRealFile = isNetwork || (!kIsWeb && file != null && file.existsSync());

    if (hasRealFile && media.type == MediaType.photo) {
      return EditedImage(
        media: media,
        fit: BoxFit.contain,
        watermarkUrl: watermarkUrl,
      );
    } else {
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
        child: Center(
          child: Icon(
            media.type == MediaType.photo
                ? Icons.image_rounded
                : Icons.play_circle_fill_rounded,
            color: Colors.white70,
            size: 64,
          ),
        ),
      );
    }
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
          _infoRow('Path', media.filePath),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor ?? Colors.white),
            SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
