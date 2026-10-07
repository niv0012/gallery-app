import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../upload/upload_queue_provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/media/face_search_actions.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/studio/share_with_client_sheet.dart';
import '../../providers/zip_job_provider.dart';

import '../media/media_details_screen.dart' show MediaDetailsArgs;
import '../media/media_grid_screen.dart' show MediaSearchArgs;
import 'widgets/album_details_header.dart';
import 'widgets/album_media_grid.dart';

/// Admin-only Album Details — reached from Albums List / Folder
/// Details. Fans out to Edit Album (which also owns delete) and to a
/// folder picker for a quick re-file, and mirrors Folder Details'
/// layout language (CustomAppBar, outlined action row, glass sections)
/// so the two entities feel like one consistent feature.
class AlbumDetailsScreen extends ConsumerStatefulWidget {
  final String albumId;

  const AlbumDetailsScreen({super.key, required this.albumId});

  @override
  ConsumerState<AlbumDetailsScreen> createState() => _AlbumDetailsScreenState();
}

class _AlbumDetailsScreenState extends ConsumerState<AlbumDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.medium,
  )..forward();
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.04),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  bool _isMoving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final media = ref.read(mediaProvider);
      
      // Load the global gallery if it hasn't been loaded at all yet.
      if (media.allMedia.isEmpty && !media.isLoading) {
        media.load();
      }

      // Also ensure we specifically load the preview media for THIS album,
      // in case its media is older than the global top 200 and would 
      // otherwise be missing from the preview grid.
      media.ensureAlbumLoaded(widget.albumId);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Opens the Add Media bottom sheet, runs the matching `image_picker`
  /// flow, and stores the result only in the local `mediaProvider` +
  /// Hive-backed repository — no uploads, no backend calls.
  /// `AlbumModel.photoCount` is kept in sync by
  /// `MediaListController.addMedia` itself (see media_provider.dart), so
  /// this screen no longer needs to touch `albumProvider` directly.
  Future<void> _openAddMediaSheet(AlbumModel album) async {
    final notifier = ref.read(uploadQueueProvider.notifier);
    await notifier.resetWizard();
    notifier.updateOptions(albumId: album.id, folderId: album.folderId);

    if (!mounted) return;
    Navigator.of(context).pushNamed(AppRoutes.newUpload);
  }

  AlbumModel? _findAlbum(List<AlbumModel> albums) {
    for (final a in albums) {
      if (a.id == widget.albumId) return a;
    }
    return null;
  }

  Future<void> _pickFolder(
      BuildContext context, AlbumModel album, List<FolderModel> folders) async {
    final selected = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: Icon(Icons.block_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
              title: Text('No folder (unfile)'),
              trailing: album.folderId == null
                  ? Icon(Icons.check_rounded, color: AppColors.primary)
                  : null,
              onTap: () => Navigator.of(ctx).pop(_UnfileSentinel.instance),
            ),
            const Divider(height: 1),
            ...folders.map(
              (f) => ListTile(
                leading: Icon(Icons.folder_rounded, color: AppColors.primary),
                title: Text(f.name),
                trailing: album.folderId == f.id
                    ? Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(f.id),
              ),
            ),
          ],
        ),
      ),
    );

    // Sheet dismissed (tap outside / swipe down) without picking anything.
    if (selected == null) return;
    final newFolderId = identical(selected, _UnfileSentinel.instance)
        ? null
        : selected as String;
    if (newFolderId == album.folderId) return;

    setState(() => _isMoving = true);
    try {
      await ref.read(albumProvider).moveToFolder(album.id, newFolderId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(newFolderId == null ? 'Album unfiled' : 'Album moved')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _isMoving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);
    final album = _findAlbum(albumState.allAlbums);

    if (albumState.isLoading && album == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Album', showBack: true),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (album == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Album', showBack: true),
        body: Center(
            child: EmptyStateCard(
          icon: Icons.search_off_rounded,
          message: 'This album no longer exists.',
        )),
      );
    }

    final folder =
        album.folderId == null ? null : folderState.folderById(album.folderId!);

    final mediaState = ref.watch(mediaProvider);
    final allAlbumMedia = mediaState.allMedia
        .where((m) => m.albumId == album.id)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    const int previewLimit = 12;
    final previewMedia =
        allAlbumMedia.take(previewLimit).toList(growable: false);

    return Scaffold(
      appBar: CustomAppBar(
        title: album.name,
        showBack: true,
        actions: [
          ...faceSearchActions(
            context,
            ref,
            albumId: album.id,
            scopeLabel: album.name,
          ),
          IconButton(
            tooltip: 'Download Album as ZIP',
            onPressed: () => _queueAlbumZip(context, ref, album),
            icon: const Icon(Icons.archive_outlined),
          ),
          IconButton(
            tooltip: 'Share with Client',
            onPressed: () => showShareWithClientSheet(
              context,
              ref,
              albumId: album.id,
              itemLabel: album.name,
            ),
            icon: Icon(Icons.person_add_alt_1_rounded),
          ),
          IconButton(
            tooltip: 'Share Settings',
            onPressed: () {
              Navigator.of(context).pushNamed(
                AppRoutes.shareLinksList,
                arguments: {
                  'albumId': album.id,
                  'title': album.name,
                },
              );
            },
            icon: Icon(Icons.share_rounded),
          ),
          IconButton(
            tooltip:
                album.isFavorite ? 'Remove from favorites' : 'Add to favorites',
            onPressed: () => ref.read(albumProvider).toggleFavorite(album.id),
            icon: Icon(
              album.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: album.isFavorite
                  ? AppColors.accent
                  : (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Two columns on wide/tablet layouts, single column on phones.
                final isWide = constraints.maxWidth >= 720;
                final content = RefreshIndicator(
                  onRefresh: () async {
                    await ref.read(albumProvider).load();
                    await ref.read(mediaProvider).load();
                  },
                  child: ListView(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    children: [
                      AlbumDetailsHeader(album: album),
                      SizedBox(height: AppSpacing.md),
                      if (folder != null || album.description != null)
                        Builder(builder: (context) {
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;
                          return Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(AppSpacing.md),
                            margin: EdgeInsets.only(bottom: AppSpacing.lg),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppColors.darkSurface
                                  : Colors.white.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                              border: Border.all(
                                  color: isDark
                                      ? AppColors.darkBorder
                                      : AppColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (album.description != null) ...[
                                  Text(
                                    album.description!,
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500,
                                        color: isDark
                                            ? AppColors.textOnDark
                                            : (Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? AppColors.textOnDark
                                                : AppColors.text)),
                                  ),
                                  if (folder != null)
                                    SizedBox(height: AppSpacing.sm),
                                ],
                                if (folder != null)
                                  Row(
                                    children: [
                                      Icon(Icons.folder_rounded,
                                          size: 16, color: AppColors.primary),
                                      SizedBox(width: 6),
                                      Text(
                                        'Filed under "${folder.name}"',
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.primary),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        }),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.of(context).pushNamed(
                                AppRoutes.adminAlbumEdit,
                                arguments: album.id,
                              ),
                              icon: Icon(Icons.edit_outlined),
                              label: Text('Edit Album'),
                            ),
                          ),
                          SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isMoving
                                  ? null
                                  : () => _pickFolder(
                                      context, album, folderState.folders),
                              icon: _isMoving
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : Icon(Icons.drive_file_move_rounded),
                              label: Text('Move'),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: AppSpacing.sm),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: () => Navigator.of(context)
                              .pushNamed(AppRoutes.adminFolderList),
                          icon: Icon(Icons.folder_open_rounded),
                          label: Text('Manage Folders'),
                        ),
                      ),
                      SizedBox(height: AppSpacing.xl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Recent Media',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.textOnDark
                                    : (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.textOnDark
                                        : AppColors.text)),
                          ),
                          if (allAlbumMedia.isNotEmpty)
                            TextButton(
                              onPressed: () => Navigator.of(context).pushNamed(
                                AppRoutes.media,
                                arguments:
                                    MediaSearchArgs(initialAlbumId: album.id),
                              ),
                              child: Text('Manage Media',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                            ),
                        ],
                      ),
                      SizedBox(height: AppSpacing.md),
                      if (previewMedia.isEmpty && mediaState.isLoading)
                        Container(
                          width: double.infinity,
                          height: 160,
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? AppColors.darkSurface
                                : Colors.white.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(AppRadius.xl),
                            border: Border.all(
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.darkBorder
                                    : AppColors.border),
                          ),
                          child: const Center(child: CircularProgressIndicator()),
                        )
                      else
                        AlbumMediaGrid(
                          media: previewMedia,
                          onAddMedia: () => _openAddMediaSheet(album),
                          onTapMedia: (m) => Navigator.of(context).pushNamed(
                            AppRoutes.mediaDetails,
                            arguments: MediaDetailsArgs(
                              mediaId: m.id,
                              mediaIds: previewMedia
                                  .map((x) => x.id)
                                  .toList(growable: false),
                            ),
                          ),
                        ),
                    ],
                  ),
                );

                if (!isWide) return content;

                // Wide layout: header/actions in a constrained centered
                // column so the screen doesn't stretch awkwardly on
                // tablets/desktop, matching the auth flow's maxWidth pattern.
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: content,
                  ),
                );
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'album_details_fab',
        tooltip: 'Add Media',
        onPressed: () => _openAddMediaSheet(album),
        child: Icon(Icons.add_rounded),
      ),
    );
  }

  Future<void> _queueAlbumZip(
      BuildContext context, WidgetRef ref, AlbumModel album) async {
    try {
      await ref.read(zipJobsProvider.notifier).createJob(
            kind: 'zip_album',
            targetId: album.id,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('ZIP job queued! Track progress in Downloads.'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.zipJobs),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not queue ZIP: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }
}


/// Distinguishes "user picked No folder" from "sheet dismissed with no
/// selection" since both would otherwise read as a null result.
class _UnfileSentinel {
  const _UnfileSentinel._();
  static const instance = _UnfileSentinel._();
}
