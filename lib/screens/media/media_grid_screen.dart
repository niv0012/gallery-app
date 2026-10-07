import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';

import '../../core/routes/app_routes.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../models/album_model.dart';
import '../../providers/auth_providers.dart' show apiClientProvider;
import '../../providers/media_provider.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/pinch_zoom_grid.dart';
import '../../services/share_service_impl.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../widgets/media/face_search_actions.dart';

import 'media_details_screen.dart';
import '../../widgets/media/edited_image.dart';
import '../../widgets/media/video_fallback_thumbnail.dart';
import 'media_batch_workflows.dart';
import '../../widgets/media/media_thumb_badges.dart';
import '../../widgets/media/media_thumb.dart';
import '../../widgets/admin/fade_slide_in.dart';
import '../../widgets/common/compact_anchored_dropdown.dart';
import '../../core/theme/theme_context.dart';

const _gridFileCache = MediaFileCache();
const _gridShareService = ShareServiceImpl();
const _gridDownloadService = DownloadServiceImpl();

/// Shares a single [MediaModel], resolving network/local media and
/// branching to the bytes-based path on web where `dart:io` File paths
/// don't work.
Future<void> _shareSingleMedia(BuildContext context, MediaModel m) async {
  if (kIsWeb) {
    final result = await _gridFileCache.bytesFor(m);
    if (result == null) return;
    if (!context.mounted) return;
    await _gridShareService.shareMediaBytes(
      context: context,
      bytes: result.bytes,
      fileName: result.fileName,
    );
    return;
  }

  final filePath = await _gridFileCache.localPathFor(m);
  if (filePath == null) return;
  if (!context.mounted) return;
  await _gridShareService.shareMedia(context: context, filePath: filePath);
}

/// Downloads/saves a single [MediaModel], resolving network/local media
/// and branching to the bytes-based path on web.
Future<void> _downloadSingleMedia(
    BuildContext context, WidgetRef ref, MediaModel m) async {
  final apiClient = ref.read(apiClientProvider);
  if (kIsWeb) {
    final result = await _gridFileCache.bytesFor(m);
    if (result == null) return;
    if (!context.mounted) return;
    await _gridDownloadService.downloadBytes(
      context: context,
      bytes: result.bytes,
      fileName: result.fileName,
      mediaId: m.id,
      apiClient: apiClient,
    );
    return;
  }

  final filePath = await _gridFileCache.localPathFor(m);
  if (filePath == null) return;
  if (!context.mounted) return;
  await _gridDownloadService.downloadOriginal(
    context: context,
    filePath: filePath,
    mediaId: m.id,
    apiClient: apiClient,
  );
}

class _ErrorStateCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorStateCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(AppSpacing.lg),
      child: Container(
        padding: EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.darkSurfaceRaised
              : Colors.white.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.darkBorder
                  : AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: AppColors.error),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                    fontWeight: FontWeight.w800,
                  ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                  ),
            ),
            SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Media grid/list screen for photos/videos.
///
/// Interaction rules:
/// - Normal mode: tap opens Media Details (which fans out to the Image
///   Viewer / Video Player).
/// - Long press starts selection.
/// - Selection mode: taps toggle selection only.
class MediaGridScreen extends ConsumerStatefulWidget {
  final String? albumId;
  final String? folderId;
  final bool favoritesOnly;
  final bool unfiledOnly;

  /// Optional hard type filter. When set to [MediaType.video] this is the
  /// Video Grid; [MediaType.photo] is the Photo Grid; `null` shows both,
  /// matching the existing combined-grid architecture.
  final MediaType? type;
  final String? likedByClientId;
  final bool showBack;

  const MediaGridScreen({
    super.key,
    this.albumId,
    this.folderId,
    this.favoritesOnly = false,
    this.unfiledOnly = false,
    this.type,
    this.likedByClientId,
    this.showBack = true,
  });

  @override
  ConsumerState<MediaGridScreen> createState() => _MediaGridScreenState();
}

enum _GalleryViewMode { grid, list, timeline }

enum _GalleryGroupMode { none, date, folder, album }

class _MediaGridScreenState extends ConsumerState<MediaGridScreen>
    with SingleTickerProviderStateMixin, RouteAware {
  _GalleryViewMode _viewMode = _GalleryViewMode.grid;
  // Default to album grouping when no album filter is set — so all
  // photos appear organized by album. When an albumId IS set (i.e.
  // "Manage Photos" opened from a specific album), use flat grid since
  // the content is already scoped to a single album.
  late _GalleryGroupMode _groupMode;
  final ScrollController _scrollController = ScrollController();
  int _visibleLimit = 120;
  int _gridColumns = 4;

  // GestureDetector-based scale tracking – works for both touch pinch
  // and trackpad pinch-to-zoom on Flutter Web.
  double _scaleStartModeIndex = 2.0;

  int get _currentModeIndex => _viewMode == _GalleryViewMode.timeline
      ? 3
      : _viewMode == _GalleryViewMode.grid
          ? 2
          : 1;

  void _zoomIn() {
    if (_viewMode == _GalleryViewMode.timeline) {
      _changeViewMode(_GalleryViewMode.grid);
      setState(() {
        _gridColumns = 8;
      });
    } else if (_viewMode == _GalleryViewMode.grid) {
      if (_gridColumns > 1) {
        setState(() {
          _gridColumns--;
        });
      } else {
        _changeViewMode(_GalleryViewMode.list);
      }
    }
  }

  void _zoomOut() {
    if (_viewMode == _GalleryViewMode.list) {
      _changeViewMode(_GalleryViewMode.grid);
      setState(() {
        _gridColumns = 1;
      });
    } else if (_viewMode == _GalleryViewMode.grid) {
      if (_gridColumns < 8) {
        setState(() {
          _gridColumns++;
        });
      } else {
        _changeViewMode(_GalleryViewMode.timeline);
      }
    }
  }

  Widget _propRow({required String label, required String value}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  late final AnimationController _favoriteAnim;

  @override
  void initState() {
    super.initState();
    // When scoped to a specific album, show a date-grouped grid (content is
    // already album-filtered). When showing all media, default to
    // album grouping so photos appear organized by album.
    _groupMode = widget.albumId != null
        ? _GalleryGroupMode.date
        : _GalleryGroupMode.album;

    _favoriteAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    // Attach listener for lazy loading (infinite scroll)
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        _loadMoreMedia();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyFilters();

      final settings = ref.read(settingsProvider);
      if (settings.galleryViewMode == 'List') {
        setState(() => _viewMode = _GalleryViewMode.list);
      } else if (settings.galleryViewMode == 'Timeline') {
        setState(() => _viewMode = _GalleryViewMode.timeline);
      } else {
        setState(() => _viewMode = _GalleryViewMode.grid);
      }
    });
  }

  void _changeViewMode(_GalleryViewMode mode) {
    setState(() => _viewMode = mode);
    final settings = ref.read(settingsProvider);
    String modeStr = 'Grid';
    if (mode == _GalleryViewMode.list) modeStr = 'List';
    if (mode == _GalleryViewMode.timeline) modeStr = 'Timeline';
    ref
        .read(settingsProvider.notifier)
        .updateSettings(settings.copyWith(galleryViewMode: modeStr));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _favoriteAnim.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() => _applyFilters();

  void _applyFilters() {
    final c = ref.read(mediaProvider);
    c.setAlbum(widget.albumId);
    c.setFolder(widget.folderId);
    c.setFilterOption(widget.favoritesOnly
        ? MediaFilterOption.favorites
        : MediaFilterOption.all);
    c.setType(widget.type);
    c.setLikedByClientId(widget.likedByClientId);
    c.setUnfiledOnly(widget.unfiledOnly);
    _resetPagination();
  }

  void _resetPagination() {
    setState(() {
      _visibleLimit = 120;
    });
  }

  void _loadMoreMedia() {
    final c = ref.read(mediaProvider);
    if (c.isLoadingMore || !c.hasMore) return;
    c.loadMore();
  }

  // Group media models by date of creation/modification, folder, or album.
  Map<String, List<MediaModel>> _groupMedia(
      List<MediaModel> list, _GalleryGroupMode mode) {
    final groups = <String, List<MediaModel>>{};
    final folderState = ref.read(folderProvider);
    final albumState = ref.read(albumProvider);

    for (final m in list) {
      String key;
      switch (mode) {
        case _GalleryGroupMode.none:
          key = 'All Media';
          break;
        case _GalleryGroupMode.date:
          key = _formatGroupDate(m.createdAt);
          break;
        case _GalleryGroupMode.folder:
          if (m.folderId == null) {
            key = 'Unfiled (Root)';
          } else {
            key = folderState.folderById(m.folderId!)?.name ??
                'Folder: ${m.folderId}';
          }
          break;
        case _GalleryGroupMode.album:
          if (m.albumId == null) {
            key = 'Unfiled';
          } else {
            final album = albumState.allAlbums.cast<AlbumModel?>().firstWhere(
                  (a) => a?.id == m.albumId,
                  orElse: () => null,
                );
            key = album?.name ?? 'Album: ${m.albumId}';
          }
          break;
      }
      groups.putIfAbsent(key, () => []).add(m);
    }
    return groups;
  }

  String _formatGroupDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final target = DateTime(date.year, date.month, date.day);

    if (target == today) return 'Today';
    if (target == yesterday) return 'Yesterday';

    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Future<void> _confirmDeleteOne(String id) async {
    final confirmed = await _showDeleteBottomSheet(
      count: 1,
      subtitle: 'This photo will be moved to trash.',
    );
    if (confirmed != true || !mounted) return;

    final controller = ref.read(mediaProvider);
    controller.toggleSelected(id);
    final ids = controller.selectedIds.toList(growable: false);
    final deletedBackup = controller.allMedia
        .where((m) => ids.contains(m.id))
        .toList(growable: false);

    await controller.batchDelete();

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
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
          onPressed: () async {
            await controller.restoreDeletedMedia(deletedBackup);
          },
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      messenger.hideCurrentSnackBar();
    });
  }

  Future<void> _renameSelectedItems() async {
    final c = ref.read(mediaProvider);
    final ids = c.selectedIds.toList(growable: false);
    if (ids.isEmpty) return;

    if (ids.length != 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Rename supports selecting exactly 1 item.')),
      );
      return;
    }

    final mediaId = ids.first;
    final item = c.allMedia.firstWhere((m) => m.id == mediaId);

    final newName = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: item.fileName);
        return AlertDialog(
          title: Text('Rename'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'File name',
                  hintText: 'e.g. IMG_001.jpg',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () {
                Navigator.of(ctx).pop(controller.text);
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );

    if (newName == null || !mounted) return;

    await c.renameMediaById(mediaId: mediaId, newFileName: newName);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Media renamed')),
    );
  }

  Future<void> _showPropertiesForSelection() async {
    final c = ref.read(mediaProvider);
    final ids = c.selectedIds.toList(growable: false);
    if (ids.isEmpty) return;

    final first = c.allMedia.firstWhere((m) => m.id == ids.first);

    final albumName = first.albumId == null
        ? 'Unfiled'
        : ref
            .read(albumProvider)
            .allAlbums
            .firstWhere((a) => a.id == first.albumId)
            .name;
    final folderName = first.folderId == null
        ? 'Root level (unfiled)'
        : ref
            .read(folderProvider)
            .folders
            .firstWhere((f) => f.id == first.folderId)
            .name;

    String extension;
    final dot = first.fileName.lastIndexOf('.');
    extension = (dot > 0 && dot < first.fileName.length - 1)
        ? first.fileName.substring(dot + 1).toUpperCase()
        : '';

    final sizeLabel =
        '${(first.size / 1024).toStringAsFixed(first.size >= 1024 * 1024 ? 1 : 0)} KB';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Properties'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _propRow(label: 'File name', value: first.fileName),
                _propRow(
                    label: 'File type',
                    value: first.type == MediaType.photo ? 'Photo' : 'Video'),
                _propRow(
                    label: 'File extension',
                    value: extension.isEmpty ? '—' : extension),
                _propRow(label: 'File size', value: sizeLabel),
                _propRow(
                  label: 'Resolution',
                  value: '${first.width} x ${first.height}',
                ),
                if (first.type == MediaType.video)
                  _propRow(
                    label: 'Duration',
                    value: first.duration == null
                        ? '—'
                        : MediaFormatUtils.formatDuration(first.duration!),
                  ),
                _propRow(label: 'Album', value: albumName),
                _propRow(label: 'Folder', value: folderName),
                _propRow(
                  label: 'Created',
                  value: first.createdAt.toLocal().toString().split('.').first,
                ),
                _propRow(
                  label: 'Modified',
                  value: first.modifiedAt.toLocal().toString().split('.').first,
                ),
                _propRow(
                  label: 'Favorite',
                  value: first.isFavorite ? 'Yes' : 'No',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteSelection() async {
    final controller = ref.read(mediaProvider);
    final ids = controller.selectedIds.toList(growable: false);
    if (ids.isEmpty) return;

    final confirmed = await _showDeleteBottomSheet(
      count: ids.length,
      subtitle: ids.length == 1
          ? 'This photo will be moved to trash.'
          : '${ids.length} items will be moved to trash.',
    );

    if (confirmed != true || !mounted) return;

    final deletedBackup = controller.allMedia
        .where((m) => ids.contains(m.id))
        .toList(growable: false);

    await controller.batchDelete();

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.success,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(
            ids.length == 1
                ? 'Moved to trash'
                : '${ids.length} items moved to trash',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        action: SnackBarAction(
          label: 'Undo',
          textColor: Colors.white,
          onPressed: () async {
            await controller.restoreDeletedMedia(deletedBackup);
          },
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      messenger.hideCurrentSnackBar();
    });
  }

  /// Shows a modern bottom-sheet delete confirmation.
  Future<bool?> _showDeleteBottomSheet({
    required int count,
    required String subtitle,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<bool>(
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
            // Drag handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            // Red delete icon
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child:
                  Icon(Icons.delete_rounded, color: AppColors.error, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              count == 1 ? 'Delete Photo?' : 'Delete $count Items?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.textOnDark : AppColors.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
              ),
            ),
            const SizedBox(height: 28),
            // Delete button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.delete_rounded, color: Colors.white),
                label: Text(
                  count == 1 ? 'Delete' : 'Delete $count Items',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16),
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ),
            const SizedBox(height: 12),
            // Cancel button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  side: BorderSide(
                      color: isDark ? AppColors.darkBorder : AppColors.border),
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
  }

  Future<void> _favoriteSelection(MediaListController c) async {
    final ids = c.selectedIds;
    if (ids.isEmpty) return;

    final anyNotFav = ids.any(
        (id) => c.allMedia.firstWhere((m) => m.id == id).isFavorite == false);
    final count = ids.length;

    await c.batchFavorite(favorite: anyNotFav);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(anyNotFav
            ? '$count item${count == 1 ? '' : 's'} added to favorites'
            : '$count item${count == 1 ? '' : 's'} removed from favorites'),
      ),
    );
  }

  Future<void> _toggleFavoriteSingle(String id) async {
    final c = ref.read(mediaProvider);
    await c.toggleFavorite(id);
    _favoriteAnim.forward(from: 0);
  }

  // ---------------------------------------------------------------------
  // View Rendering Methods
  // ---------------------------------------------------------------------

  // Standard Grid View
  Widget _buildGridView(
      MediaListController c, List<MediaModel> media, int limit) {
    final displayItems = media;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _gridColumns;

        return GridView.builder(
          controller: _scrollController,
          padding: EdgeInsets.all(AppSpacing.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
            childAspectRatio: 1,
          ),
          itemCount: displayItems.length + (c.isLoadingMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == displayItems.length) {
              return Center(
                  child: Padding(
                      padding: EdgeInsets.all(12.0),
                      child: CircularProgressIndicator()));
            }
            final m = displayItems[i];
            return FadeSlideIn(
              delay: Duration(milliseconds: (i % 8) * 50),
              child: _buildTileItem(c, m, media),
            );
          },
        );
      },
    );
  }

  // Grouped Grid/List View
  Widget _buildGroupedView(
    MediaListController c,
    List<MediaModel> media,
    int limit,
    _GalleryGroupMode groupMode,
    _GalleryViewMode viewMode,
  ) {
    final displayItems = media;
    final grouped = _groupMedia(displayItems, groupMode);
    final groupKeys = grouped.keys.toList();

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: 16),
      itemCount: groupKeys.length + (c.isLoadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == groupKeys.length) {
          return Center(
              child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator()));
        }
        final groupKey = groupKeys[i];
        final items = grouped[groupKey]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                groupKey,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text),
                    ),
              ),
            ),
            if (viewMode == _GalleryViewMode.grid)
              LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = _gridColumns;

                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: AppSpacing.sm,
                      crossAxisSpacing: AppSpacing.sm,
                      childAspectRatio: 1,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, idx) => FadeSlideIn(
                      delay: Duration(milliseconds: (idx % 8) * 50),
                      child: _buildTileItem(c, items[idx], media),
                    ),
                  );
                },
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: items.length,
                itemBuilder: (context, idx) {
                  final m = items[idx];
                  final selected = c.selectedIds.contains(m.id);
                  return FadeSlideIn(
                    delay: Duration(milliseconds: (idx % 8) * 50),
                    child: _MediaListRow(
                      media: m,
                      selected: selected,
                      isSelectionMode: c.isSelectionMode,
                      onTap: () {
                        if (c.isSelectionMode) {
                          c.toggleSelected(m.id);
                          return;
                        }
                        Navigator.of(context).pushNamed(
                          AppRoutes.mediaDetails,
                          arguments: MediaDetailsArgs(
                            mediaId: m.id,
                            mediaIds:
                                media.map((x) => x.id).toList(growable: false),
                          ),
                        );
                      },
                      onLongPress: () {
                        if (!c.isSelectionMode) {
                          c.toggleSelected(m.id);
                        }
                      },
                      onToggleFavorite: () async {
                        if (c.isSelectionMode) return;
                        await _toggleFavoriteSingle(m.id);
                      },
                      onDelete: () => _confirmDeleteOne(m.id),
                      onRename: () async {
                        final prevSelection = c.selectedIds.toList();
                        c.clearSelection();
                        c.toggleSelected(m.id);
                        await _renameSelectedItems();
                        c.clearSelection();
                        for (final id in prevSelection) {
                          c.toggleSelected(id);
                        }
                      },
                      onProperties: () async {
                        final prevSelection = c.selectedIds.toList();
                        c.clearSelection();
                        c.toggleSelected(m.id);
                        await _showPropertiesForSelection();
                        c.clearSelection();
                        for (final id in prevSelection) {
                          c.toggleSelected(id);
                        }
                      },
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  // List View
  Widget _buildListView(
      MediaListController c, List<MediaModel> media, int limit) {
    final displayItems = media;

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: 8),
      itemCount: displayItems.length + (c.isLoadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == displayItems.length) {
          return Center(
              child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator()));
        }
        final m = displayItems[i];
        final selected = c.selectedIds.contains(m.id);

        return FadeSlideIn(
          delay: Duration(milliseconds: (i % 8) * 50),
          child: _MediaListRow(
            media: m,
            selected: selected,
            isSelectionMode: c.isSelectionMode,
            onTap: () {
              if (c.isSelectionMode) {
                c.toggleSelected(m.id);
                return;
              }
              Navigator.of(context).pushNamed(
                AppRoutes.mediaDetails,
                arguments: MediaDetailsArgs(
                  mediaId: m.id,
                  mediaIds: media.map((x) => x.id).toList(growable: false),
                ),
              );
            },
            onLongPress: () {
              if (!c.isSelectionMode) {
                c.toggleSelected(m.id);
              }
            },
            onToggleFavorite: () async {
              if (c.isSelectionMode) return;
              await _toggleFavoriteSingle(m.id);
            },
            onDelete: () => _confirmDeleteOne(m.id),
            onRename: () async {
              final prevSelection = c.selectedIds.toList();
              c.clearSelection();
              c.toggleSelected(m.id);
              await _renameSelectedItems();
              c.clearSelection();
              for (final id in prevSelection) {
                c.toggleSelected(id);
              }
            },
            onProperties: () async {
              final prevSelection = c.selectedIds.toList();
              c.clearSelection();
              c.toggleSelected(m.id);
              await _showPropertiesForSelection();
              c.clearSelection();
              for (final id in prevSelection) {
                c.toggleSelected(id);
              }
            },
          ),
        );
      },
    );
  }

  // Timeline View
  Widget _buildTimelineView(
      MediaListController c, List<MediaModel> media, int limit) {
    final displayItems = media;
    final grouped = _groupMedia(displayItems, _GalleryGroupMode.date);
    final dates = grouped.keys.toList();

    return Stack(
      children: [
        Positioned(
          left: 20, // Aligns with the circle indicators
          top: 0,
          bottom: 0,
          child: Container(
            width: 2,
            color: AppColors.primary.withValues(alpha: 0.15),
          ),
        ),
        CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            for (int i = 0; i < dates.length; i++) ...[
              SliverPersistentHeader(
                pinned: true,
                delegate: _TimelineHeaderDelegate(
                  date: dates[i],
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(40, 8, 16, 20),
                sliver: _buildTimelineGridSliver(c, grouped[dates[i]]!, media),
              ),
            ],
            if (c.isLoadingMore)
              const SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimelineGridSliver(MediaListController c, List<MediaModel> items,
      List<MediaModel> mediaList) {
    final crossAxisCount = _gridColumns;

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.0,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, idx) {
          final m = items[idx];
          return FadeSlideIn(
            delay: Duration(milliseconds: (idx % 6) * 50),
            child: _buildTileItem(c, m, mediaList),
          );
        },
        childCount: items.length,
      ),
    );
  }

  // Shared builder for Grid / Timeline thumbnails
  Widget _buildTileItem(
      MediaListController c, MediaModel m, List<MediaModel> mediaList) {
    final selected = c.selectedIds.contains(m.id);
    return _MediaTile(
      media: m,
      selected: selected,
      onTap: () {
        if (c.isSelectionMode) {
          c.toggleSelected(m.id);
          return;
        }
        Navigator.of(context).pushNamed(
          AppRoutes.mediaDetails,
          arguments: MediaDetailsArgs(
            mediaId: m.id,
            mediaIds: mediaList.map((x) => x.id).toList(growable: false),
          ),
        );
      },
      onLongPress: () {
        if (!c.isSelectionMode) {
          c.toggleSelected(m.id);
        }
      },
      onToggleFavorite: () async {
        if (c.isSelectionMode) return;
        await _toggleFavoriteSingle(m.id);
      },
      onDelete: () => _confirmDeleteOne(m.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(mediaProvider);
    final media = c.filteredMedia;

    final errorView = c.lastError == null
        ? null
        : mapNetworkError(
            ApiException(-1, c.lastError!),
          );
    // Resolve album name for the title when this screen is scoped to one
    final scopedAlbumName = widget.albumId == null
        ? null
        : ref
            .read(albumProvider)
            .allAlbums
            .cast<AlbumModel?>()
            .firstWhere((a) => a?.id == widget.albumId, orElse: () => null)
            ?.name;

    return Scaffold(
      appBar: CustomAppBar(
        title: c.isSelectionMode
            ? '${c.selectedIds.length} selected'
            : widget.favoritesOnly
                ? 'Favorites'
                : scopedAlbumName ??
                    (widget.type == MediaType.video
                        ? 'Videos'
                        : widget.type == MediaType.photo
                            ? 'Photos'
                            : 'All Media'),
        showBack: widget.showBack,
        actions: [
          if (c.isSelectionMode) ...[
            IconButton(
              tooltip: 'Select Liked',
              icon: Icon(Icons.favorite_rounded),
              onPressed: () {
                final likedIds = media.where((m) => m.likeCount > 0).map((m) => m.id).toList();
                if (likedIds.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('No liked photos found in this view.')),
                  );
                  return;
                }
                for (final id in likedIds) {
                  if (!c.selectedIds.contains(id)) {
                    c.toggleSelected(id);
                  }
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Selected ${likedIds.length} liked photos.')),
                );
              },
            ),
            IconButton(
              tooltip: c.selectedIds.length == media.length
                  ? 'Deselect All'
                  : 'Select All',
              icon: Icon(c.selectedIds.length == media.length
                  ? Icons.deselect_rounded
                  : Icons.select_all_rounded),
              onPressed: () {
                if (c.selectedIds.length == media.length) {
                  c.clearSelection();
                } else {
                  c.selectAll();
                }
              },
            ),
            IconButton(
              tooltip: 'Exit selection',
              icon: Icon(Icons.close_rounded),
              onPressed: () => c.clearSelection(),
            ),
          ] else ...[
            IconButton(
              tooltip: 'Search',
              icon: Icon(Icons.search_rounded),
              onPressed: () {
                Navigator.of(context).pushNamed(
                  AppRoutes.mediaSearch,
                  arguments: MediaSearchArgs(
                      initialAlbumId: widget.albumId,
                      initialFolderId: widget.folderId,
                      favoritesOnly: widget.favoritesOnly),
                );
              },
            ),
            ...faceSearchActions(
              context,
              ref,
              albumId: widget.albumId,
              folderId: widget.folderId,
              scopeLabel: widget.albumId != null ? 'this album' : (widget.folderId != null ? 'this folder' : null),
            ),
            if (widget.type == null && !widget.favoritesOnly)
              IconButton(
                tooltip: 'Videos',
                icon: Icon(Icons.video_library_rounded),
                onPressed: () {
                  Navigator.of(context).pushNamed(
                    AppRoutes.videoGrid,
                    arguments: MediaSearchArgs(
                        initialAlbumId: widget.albumId,
                        initialFolderId: widget.folderId),
                  );
                },
              ),
            IconButton(
              tooltip: 'Favorites',
              icon: Icon(Icons.favorite_rounded),
              onPressed: () {
                Navigator.of(context).pushNamed(
                  AppRoutes.mediaFavorites,
                );
              },
            ),
          ]
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: c.isLoading && media.isEmpty
            ? Center(child: LoadingWidget(message: c.loadingMessage))
            : c.lastError != null && media.isEmpty
                ? Center(
                    child: _ErrorStateCard(
                      message: errorView ?? c.lastError!,
                      onRetry: () {
                        ref.read(mediaProvider).load();
                      },
                    ),
                  )
                : Column(
                    children: [
                      // Options Quick Action Control Toolbar
                      if (!c.isSelectionMode)
                        Container(
                          padding:
                              EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.darkSurface
                                    : Colors.white,
                            border: Border(
                                bottom: BorderSide(
                                    color: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.darkBorder
                                        : Colors.grey.shade100)),
                          ),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                // Sort selection Dropdown
                                Row(
                                  children: [
                                    Icon(Icons.sort_rounded,
                                        size: 16,
                                        color: Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? AppColors.subtitleOnDark
                                            : Colors.black45),
                                    SizedBox(width: 4),
                                    CompactAnchoredDropdown<MediaSortOption>(
                                      value: c.sortOption,
                                      iconSize: 16,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color:
                                                Theme.of(context).brightness ==
                                                        Brightness.dark
                                                    ? AppColors.textOnDark
                                                    : Colors.black87,
                                          ),
                                      items: const [
                                        DropdownMenuItem(
                                            value: MediaSortOption.recent,
                                            child: Text('Recent')),
                                        DropdownMenuItem(
                                            value: MediaSortOption.name,
                                            child: Text('Name')),
                                        DropdownMenuItem(
                                            value: MediaSortOption.size,
                                            child: Text('Size')),
                                        DropdownMenuItem(
                                            value: MediaSortOption.duration,
                                            child: Text('Duration')),
                                      ],
                                      onChanged: (val) {
                                        c.setSortOption(val);
                                      },
                                    ),
                                  ],
                                ),
                                SizedBox(width: 14),
                                // Filter Type dropdown
                                Row(
                                  children: [
                                    Icon(Icons.filter_list_rounded,
                                        size: 16,
                                        color: Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? AppColors.subtitleOnDark
                                            : Colors.black45),
                                    SizedBox(width: 4),
                                    CompactAnchoredDropdown<MediaType?>(
                                      value: c.type,
                                      iconSize: 16,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color:
                                                Theme.of(context).brightness ==
                                                        Brightness.dark
                                                    ? AppColors.textOnDark
                                                    : Colors.black87,
                                          ),
                                      items: const [
                                        DropdownMenuItem(
                                            value: null,
                                            child: Text('All Media')),
                                        DropdownMenuItem(
                                            value: MediaType.photo,
                                            child: Text('Photos')),
                                        DropdownMenuItem(
                                            value: MediaType.video,
                                            child: Text('Videos')),
                                      ],
                                      onChanged: (val) {
                                        c.setType(val);
                                        _resetPagination();
                                      },
                                    ),
                                  ],
                                ),
                                if (_viewMode != _GalleryViewMode.timeline) ...[
                                  SizedBox(width: 14),
                                  // Grouping Dropdown
                                  Row(
                                    children: [
                                      Icon(Icons.group_work_rounded,
                                          size: 16,
                                          color: Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? AppColors.subtitleOnDark
                                              : Colors.black45),
                                      SizedBox(width: 4),
                                      CompactAnchoredDropdown<
                                          _GalleryGroupMode>(
                                        value: _groupMode,
                                        iconSize: 16,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: Theme.of(context)
                                                          .brightness ==
                                                      Brightness.dark
                                                  ? AppColors.textOnDark
                                                  : Colors.black87,
                                            ),
                                        items: const [
                                          DropdownMenuItem(
                                              value: _GalleryGroupMode.none,
                                              child: Text('No Group')),
                                          DropdownMenuItem(
                                              value: _GalleryGroupMode.date,
                                              child: Text('Group Date')),
                                          DropdownMenuItem(
                                              value: _GalleryGroupMode.folder,
                                              child: Text('Group Folder')),
                                          DropdownMenuItem(
                                              value: _GalleryGroupMode.album,
                                              child: Text('Group Album')),
                                        ],
                                        onChanged: (val) {
                                          setState(() => _groupMode = val);
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                                SizedBox(width: 24),
                                // View mode togglers
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: 'Change View Mode',
                                  icon: Icon(
                                    _viewMode == _GalleryViewMode.grid
                                        ? Icons.grid_view_rounded
                                        : _viewMode == _GalleryViewMode.list
                                            ? Icons.view_list_rounded
                                            : Icons.calendar_view_day_rounded,
                                    size: 18,
                                    color: AppColors.primary,
                                  ),
                                  onPressed: () {
                                    if (_viewMode == _GalleryViewMode.grid) {
                                      _changeViewMode(_GalleryViewMode.list);
                                    } else if (_viewMode ==
                                        _GalleryViewMode.list) {
                                      _changeViewMode(
                                          _GalleryViewMode.timeline);
                                    } else {
                                      _changeViewMode(_GalleryViewMode.grid);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (c.isSelectionMode)
                        _SelectionToolbar(
                          count: c.selectedIds.length,
                          onClear: () => c.clearSelection(),
                          onSelectAll: () => c.selectAll(),
                          onMove: () async {
                            final controller = ref.read(mediaProvider);
                            final ids =
                                controller.selectedIds.toList(growable: false);
                            if (ids.isEmpty) return;
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text('Move selected media?'),
                                content: Text(
                                    'This will move ${ids.length} item(s) to a destination.'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(false),
                                    child: Text('Cancel'),
                                  ),
                                  FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.primary),
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(true),
                                    child: Text('Move'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                            await MediaBatchWorkflows.openMove(
                                context: context, mediaIds: ids);
                          },
                          onCopy: () async {
                            final controller = ref.read(mediaProvider);
                            final ids =
                                controller.selectedIds.toList(growable: false);
                            if (ids.isEmpty) return;
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text('Copy selected media?'),
                                content: Text(
                                    'This will copy ${ids.length} item(s) to a destination.'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(false),
                                    child: Text('Cancel'),
                                  ),
                                  FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.primary),
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(true),
                                    child: Text('Copy'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                            await MediaBatchWorkflows.openCopy(
                                context: context, mediaIds: ids);
                          },
                          onDelete: _confirmDeleteSelection,
                          onShare: () async {
                            final controller = ref.read(mediaProvider);
                            final ids =
                                controller.selectedIds.toList(growable: false);
                            if (ids.isEmpty) return;

                            for (final id in ids) {
                              final m = controller.allMedia
                                  .firstWhere((x) => x.id == id);
                              if (m.displayPath.trim().isEmpty) continue;
                              if (!context.mounted) return;
                              await _shareSingleMedia(context, m);
                            }
                          },
                          onDownload: () async {
                            final controller = ref.read(mediaProvider);
                            final ids =
                                controller.selectedIds.toList(growable: false);
                            if (ids.isEmpty) return;

                            for (final id in ids) {
                              final m = controller.allMedia
                                  .firstWhere((x) => x.id == id);
                              if (m.displayPath.trim().isEmpty) continue;
                              if (!context.mounted) return;
                              await _downloadSingleMedia(context, ref, m);
                            }
                          },
                          onRename: () async {
                            await _renameSelectedItems();
                          },
                          onProperties: () async {
                            await _showPropertiesForSelection();
                          },
                          onFavorite: () => _favoriteSelection(c),
                        ),
                      Expanded(
                        child: media.isEmpty
                            ? Center(
                                child: EmptyStateCard(
                                  icon: widget.favoritesOnly
                                      ? Icons.favorite_outline_rounded
                                      : (widget.type == MediaType.video
                                          ? Icons.videocam_outlined
                                          : Icons.photo_library_outlined),
                                  message:
                                      'No media found for the current filters.',
                                ),
                              )
                            : PinchZoomGrid(
                                onZoomIn: _zoomIn,
                                onZoomOut: _zoomOut,
                                child: RefreshIndicator(
                                  onRefresh: () async {
                                    await ref.read(mediaProvider).load();
                                    _resetPagination();
                                  },
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 250),
                                      transitionBuilder: (child, animation) {
                                        // Only the incoming child (the one matching the
                                        // current view/group mode) keeps its Heroes active.
                                        // The outgoing child is still mounted for the
                                        // duration of the crossfade, so without this its
                                        // Hero tags (e.g. 'media-$id') would briefly exist
                                        // twice in this subtree and Flutter would throw
                                        // "multiple heroes that share the same tag".
                                        //
                                        // NOTE: transitionBuilder is only invoked once per
                                        // child, at the moment it *becomes* incoming - it is
                                        // NOT re-invoked later when that same child is
                                        // displaced and starts fading out. So the incoming/
                                        // outgoing state must be read live from the
                                        // animation's own direction on every frame (via
                                        // AnimatedBuilder), not computed once here by
                                        // comparing keys - that comparison is always true
                                        // and never actually disables the outgoing Hero.
                                        return FadeTransition(
                                          opacity: animation,
                                          child: AnimatedBuilder(
                                            animation: animation,
                                            child: child,
                                            builder: (context, child) {
                                              final isOutgoing =
                                                  animation.status ==
                                                      AnimationStatus.reverse;
                                              return HeroMode(
                                                enabled: !isOutgoing,
                                                child: child!,
                                              );
                                            },
                                          ),
                                        );
                                      },
                                      child: KeyedSubtree(
                                        key: ValueKey((_viewMode, _groupMode)),
                                        child: switch (_viewMode) {
                                          _GalleryViewMode.grid =>
                                            _groupMode == _GalleryGroupMode.none
                                                ? _buildGridView(
                                                    c, media, _visibleLimit)
                                                : _buildGroupedView(
                                                    c,
                                                    media,
                                                    _visibleLimit,
                                                    _groupMode,
                                                    _GalleryViewMode.grid),
                                          _GalleryViewMode.list =>
                                            _groupMode == _GalleryGroupMode.none
                                                ? _buildListView(
                                                    c, media, _visibleLimit)
                                                : _buildGroupedView(
                                                    c,
                                                    media,
                                                    _visibleLimit,
                                                    _groupMode,
                                                    _GalleryViewMode.list),
                                          _GalleryViewMode.timeline =>
                                            _buildTimelineView(
                                                c, media, _visibleLimit),
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Gallery List Row layout
// ---------------------------------------------------------------------
class _MediaListRow extends ConsumerWidget {
  final MediaModel media;
  final bool selected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onProperties;

  const _MediaListRow({
    required this.media,
    required this.selected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
    required this.onDelete,
    required this.onRename,
    required this.onProperties,
  });

  String _humanBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateStr = media.modifiedAt.toLocal().toString().split(' ').first;
    final sizeStr = _humanBytes(media.size);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.darkSurface
                  : Colors.white),
          border: Border(
              bottom: BorderSide(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? AppColors.darkBorder
                      : Colors.grey.shade100)),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Hero(
                // Suffixed with "-list" so this can never collide with the
                // grid tile's Hero for the same media item. Both can be
                // mounted at once for ~250ms during the grid/list
                // AnimatedSwitcher crossfade, and Hero tags must be unique
                // within the subtree at all times, not just at steady state.
                tag: 'media-${media.id}-list',
                child: _MediaThumbnail(media: media, selected: selected),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : Colors.black87,
                        fontSize: 13.5),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '${media.type == MediaType.photo ? "Photo" : "Video"} • $sizeStr • $dateStr',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.subtitleOnDark
                            : Colors.black45,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            SizedBox(width: 10),
            if (isSelectionMode)
              Checkbox(
                value: selected,
                onChanged: (_) => onTap(),
                activeColor: AppColors.primary,
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      media.isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: media.isFavorite
                          ? AppColors.accent
                          : (Theme.of(context).brightness == Brightness.dark
                              ? AppColors.subtitleOnDark
                              : Colors.black38),
                      size: 20,
                    ),
                    onPressed: onToggleFavorite,
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.subtitleOnDark
                            : Colors.black38,
                        size: 20),
                    surfaceTintColor: Colors.transparent,
                    onSelected: (value) async {
                      switch (value) {
                        case 'rename':
                          onRename();
                          break;
                        case 'properties':
                          onProperties();
                          break;
                        case 'share':
                          if (media.displayPath.trim().isNotEmpty) {
                            await _shareSingleMedia(context, media);
                          }
                          break;
                        case 'download':
                          if (media.displayPath.trim().isNotEmpty) {
                            await _downloadSingleMedia(context, ref, media);
                          }
                          break;
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined,
                                size: 18,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : Colors.black54),
                            SizedBox(width: 8),
                            Text('Rename'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'properties',
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                size: 18,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : Colors.black54),
                            SizedBox(width: 8),
                            Text('Properties'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'share',
                        child: Row(
                          children: [
                            Icon(Icons.share_outlined,
                                size: 18,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : Colors.black54),
                            SizedBox(width: 8),
                            Text('Share'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'download',
                        child: Row(
                          children: [
                            Icon(Icons.download_outlined,
                                size: 18,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : Colors.black54),
                            SizedBox(width: 8),
                            Text('Download'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded,
                                size: 18, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Delete', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SelectionToolbar extends StatefulWidget {
  final int count;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;
  final Future<void> Function() onMove;
  final Future<void> Function() onCopy;
  final Future<void> Function() onDelete;
  final Future<void> Function() onShare;
  final Future<void> Function() onDownload;
  final Future<void> Function() onRename;
  final Future<void> Function() onProperties;
  final Future<void> Function() onFavorite;

  const _SelectionToolbar({
    required this.count,
    required this.onClear,
    required this.onSelectAll,
    required this.onMove,
    required this.onCopy,
    required this.onDelete,
    required this.onShare,
    required this.onDownload,
    required this.onRename,
    required this.onProperties,
    required this.onFavorite,
  });

  @override
  State<_SelectionToolbar> createState() => _SelectionToolbarState();
}

class _SelectionToolbarState extends State<_SelectionToolbar> {
  bool _isBusy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_isBusy) return;
    if (widget.count == 0) return;

    setState(() => _isBusy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _onPressed(Future<void> Function() action) => _run(action);

  @override
  Widget build(BuildContext context) {
    final disabled = widget.count == 0 || _isBusy;

    return Container(
      margin: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurfaceRaised
            : Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.darkBorder
                : AppColors.border),
      ),
      child: Row(
        children: [
          Text('${widget.count} selected',
              style: TextStyle(fontWeight: FontWeight.w800)),
          SizedBox(width: AppSpacing.sm),
          // The six actions can be wider than the toolbar on narrow
          // phones (this used to overflow on the right). Let just the
          // action icons scroll horizontally instead of clipping/
          // overflowing the row — the count label above always stays
          // visible and readable.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ToolbarIcon(
                    tooltip: 'Select all',
                    icon: Icons.select_all_rounded,
                    onPressed: disabled ? null : widget.onSelectAll,
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Move',
                    icon: Icons.drive_file_move_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onMove),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Copy',
                    icon: Icons.copy_all_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onCopy),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Share',
                    icon: Icons.share_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onShare),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Download',
                    icon: Icons.download_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onDownload),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Rename',
                    icon: Icons.edit_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onRename),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Properties',
                    icon: Icons.info_outline_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onProperties),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Favorite',
                    icon: Icons.favorite_rounded,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onFavorite),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    iconColor: Colors.red,
                    onPressed:
                        disabled ? null : () => _onPressed(widget.onDelete),
                    isEnabled: !disabled,
                  ),
                  _ToolbarIcon(
                    tooltip: 'Clear selection',
                    icon: Icons.close_rounded,
                    onPressed: disabled ? null : widget.onClear,
                    isEnabled: !disabled,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact icon button used by [_SelectionToolbar]. Tighter padding and
/// constraints than the default [IconButton] (which is 48x48 with 8px
/// padding) so six of them plus the count label have a real chance of
/// fitting without overflowing on narrow phones.
class _ToolbarIcon extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color? iconColor;
  final VoidCallback? onPressed;
  final bool isEnabled;

  const _ToolbarIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.isEnabled,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: iconColor),
      iconSize: 22,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onPressed,
    );
  }
}

class _MediaTile extends StatefulWidget {
  final MediaModel media;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Future<void> Function() onToggleFavorite;
  final VoidCallback onDelete;

  const _MediaTile({
    required this.media,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
    required this.onDelete,
  });

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  @override
  Widget build(BuildContext context) {
    final m = widget.media;

    const double radius = AppRadius.lg;

    final selectionOverlay = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: widget.selected ? 1 : 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1).animate(
              CurvedAnimation(
                parent: const AlwaysStoppedAnimation(1),
                curve: Curves.easeOutCubic,
              ),
            ),
            child: Icon(
              Icons.check_circle_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ),
        ),
      ),
    );

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: EdgeInsets.all(0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: widget.selected
                ? AppColors.primary
                : (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkBorder
                    : AppColors.border),
            width: widget.selected ? 2 : 1,
          ),
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.darkSurfaceRaised
              : Colors.white.withValues(alpha: 0.92),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              Positioned.fill(
                child: Hero(
                  // Suffixed with "-grid" to match the list tile's "-list"
                  // suffix - see the note on that Hero for why this needs
                  // to be unique rather than relying on HeroMode timing.
                  tag: 'media-${m.id}-grid',
                  child: _MediaThumbnail(media: m, selected: widget.selected),
                ),
              ),

              // Type / duration badge (UI only)
              Positioned(
                left: AppSpacing.sm,
                top: AppSpacing.sm,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        m.type == MediaType.photo
                            ? Icons.photo_camera_rounded
                            : Icons.timer_rounded,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                      SizedBox(width: 6),
                      Text(
                        m.type == MediaType.photo ? 'Photo' : 'Video',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (m.type == MediaType.video && m.duration != null) ...[
                        SizedBox(width: 8),
                        Text(
                          MediaFormatUtils.formatDuration(m.duration!),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.0,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Favorite badge (UI only)
              if (m.isFavorite)
                Positioned(
                  right: AppSpacing.sm,
                  top: AppSpacing.sm,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 180),
                    scale: widget.selected ? 1.05 : 1,
                    child: Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: Icon(
                        Icons.favorite_rounded,
                        color: AppColors.accent,
                        size: 18,
                      ),
                    ),
                  ),
                ),

              // Selection overlay animation
              Positioned.fill(child: selectionOverlay),

              // Engagement badges (Likes and Comments)
              MediaThumbBadges(
                likeCount: m.likeCount,
                commentCount: m.commentCount,
                alignment: Alignment.bottomLeft,
              ),

              // Bottom actions (keep callbacks intact)
              Positioned(
                right: AppSpacing.sm,
                bottom: AppSpacing.sm,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Favorite',
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          m.isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: Colors.white,
                        ),
                        onPressed: widget.onToggleFavorite,
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(Icons.delete_outline_rounded,
                            color: Colors.white),
                        onPressed: widget.onDelete,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the actual photo (or a video's thumbnail image, if one has
/// been generated) from disk. Falls back to the gradient + icon
/// placeholder when there's no file yet, the file is missing, or it
/// fails to decode — so a broken path never crashes the grid, it just
/// looks like the old placeholder used to.
class _MediaThumbnail extends StatelessWidget {
  final MediaModel media;
  final bool selected;

  const _MediaThumbnail({required this.media, required this.selected});

  @override
  Widget build(BuildContext context) {
    if (media.type == MediaType.photo && media.editRecipe?.hasEdits == true) {
      return EditedImage(
        media: media,
        fit: BoxFit.cover,
      );
    }
    return MediaThumb(media: media, fit: BoxFit.cover);
  }

  Widget _placeholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            selected
                ? AppColors.softWash.colors.first
                : Color(media.gradientArgb.first),
            selected
                ? AppColors.softWash.colors.last
                : Color(media.gradientArgb[1]),
          ],
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
          size: 30,
        ),
      ),
    );
  }
}

/// Stub type only for route arguments.
class MediaSearchArgs {
  final String? initialAlbumId;
  final String? initialFolderId;
  final bool favoritesOnly;
  final bool unfiledOnly;

  const MediaSearchArgs({
    this.initialAlbumId,
    this.initialFolderId,
    this.favoritesOnly = false,
    this.unfiledOnly = false,
  });
}

class _TimelineHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String date;

  _TimelineHeaderDelegate({required this.date});

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      height: 40,
      color: context.bgColor.withValues(alpha: 0.95),
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: 14),
          Text(
            date,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textOnDark
                  : AppColors.text),
            ),
          ),
        ],
      ),
    );
  }

  @override
  double get maxExtent => 40.0;

  @override
  double get minExtent => 40.0;

  @override
  bool shouldRebuild(covariant _TimelineHeaderDelegate oldDelegate) {
    return oldDelegate.date != date;
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

String mapNetworkError(ApiException error) {
  switch (error.statusCode) {
    case 400:
      return "Bad request.";
    case 401:
      return "Unauthorized. Please log in again.";
    case 403:
      return "Access denied.";
    case 404:
      return "Requested resource not found.";
    case 408:
      return "Request timed out.";
    case 429:
      return "Too many requests. Please try again later.";
    case 500:
      return "Internal server error.";
    case 502:
      return "Bad gateway.";
    case 503:
      return "Service unavailable.";
    default:
      return error.message.isNotEmpty ? error.message : "Something went wrong.";
  }
}
