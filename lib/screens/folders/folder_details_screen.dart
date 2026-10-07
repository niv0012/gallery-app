import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/folder_cover_utils.dart';
import '../../models/folder_model.dart';
import '../../models/media_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../upload/upload_queue_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/media/face_search_actions.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/folder_tile.dart';
import '../../widgets/media/media_thumb.dart';
import '../../widgets/studio/share_with_client_sheet.dart';
import '../media/media_grid_screen.dart';
import '../../core/theme/theme_context.dart';
import '../../providers/zip_job_provider.dart';


/// Admin-only Folder Details — reached by tapping a folder anywhere in
/// the Folders flow (root list, or another folder's sub-folder list).
///
/// Shows, in order: this folder's own sub-folders (tap to drill in —
/// pushing this same screen again is what makes nesting work at any
/// depth), the media filed directly in this folder, and the albums
/// filed under it. The "Add Media" FAB uploads straight into this
/// folder (no album required) and only ever appears on this screen.
class FolderDetailsScreen extends ConsumerStatefulWidget {
  final String folderId;

  const FolderDetailsScreen({super.key, required this.folderId});

  @override
  ConsumerState<FolderDetailsScreen> createState() =>
      _FolderDetailsScreenState();
}

class _FolderDetailsScreenState extends ConsumerState<FolderDetailsScreen> {
  @override
  void initState() {
    super.initState();
    // Reload folders on entry so subfolders created elsewhere are visible.
    Future.microtask(() {
      if (mounted) ref.read(folderProvider).load();
    });
  }

  String get folderId => widget.folderId;

  Future<void> _addMedia(BuildContext context) async {
    final notifier = ref.read(uploadQueueProvider.notifier);
    await notifier.resetWizard();
    notifier.updateOptions(folderId: folderId, clearAlbum: true);
    if (!context.mounted) return;
    Navigator.of(context).pushNamed(AppRoutes.newUpload);
  }

  @override
  Widget build(BuildContext context) {
    final folderState = ref.watch(folderProvider);
    final folder = folderState.folderById(folderId);

    // During the initial load, show a spinner rather than "Folder not found"
    // so the screen doesn't flash an error before data arrives.
    if (folder == null) {
      return Scaffold(
        appBar: const CustomAppBar(title: 'Folder', showBack: true),
        body: Center(
          child: folderState.isLoading
              ? const CircularProgressIndicator()
              : const Text('Folder not found'),
        ),
      );
    }

    final parent = folder.parentId == null
        ? null
        : folderState.folderById(folder.parentId!);
    final ancestors = folderState.ancestorsOf(folderId);
    final subfolders = folderState.childrenOf(folder.id);

    // Same real Album -> Folder link Albums List's "Filter folder" uses
    // (AlbumModel.folderId), so this preview always matches what's
    // actually filed here instead of a stand-in approximation.
    final albumState = ref.watch(albumProvider);
    final relatedAlbums = albumState.allAlbums
        .where((a) => a.folderId == folderId)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    final mediaState = ref.watch(mediaProvider);
    final directMedia = mediaState.allMedia
        .where((m) => !m.isDeleted && m.folderId == folderId)
        .toList();

    return Scaffold(
      appBar: CustomAppBar(
        title: folder.name,
        showBack: true,
        actions: [
          ...faceSearchActions(
            context,
            ref,
            folderId: folder.id,
            scopeLabel: folder.name,
          ),
          IconButton(
            tooltip: 'Download Folder as ZIP',
            onPressed: () => _queueFolderZip(context, ref, folder),
            icon: const Icon(Icons.archive_outlined),
          ),
          IconButton(
            tooltip: 'Share Gallery Link',
            onPressed: () => Navigator.of(context).pushNamed(
              AppRoutes.folderShareSettings,
              arguments: {
                'folderId': folder.id,
                'folderName': folder.name,
              },
            ),
            icon: const Icon(Icons.link_rounded),
          ),
          IconButton(
            tooltip: 'Share with Client',
            onPressed: () => showShareWithClientSheet(
              context,
              ref,
              folderId: folder.id,
              itemLabel: folder.name,
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'folder_details_add_media_fab',
        onPressed: () => _addMedia(context),
        icon: const Icon(Icons.add_photo_alternate_rounded),
        label: const Text('Add Media'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 96),
          children: [
            if (ancestors.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.of(context).popUntil(
                        (route) =>
                            route.settings.name == AppRoutes.adminFolderList ||
                            route.isFirst,
                      ),
                      child: const Text(
                        'Folders',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    for (final ancestor in ancestors) ...[
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.chevron_right_rounded,
                            size: 16, color: context.textMuted),
                      ),
                      InkWell(
                        onTap: () => Navigator.of(context).pushNamed(
                          AppRoutes.adminFolderDetails,
                          arguments: ancestor.id,
                        ),
                        child: Text(
                          ancestor.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: folder.gradientArgb.map((a) => Color(a)).toList(),
                ),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_rounded,
                      color: Colors.white, size: 32),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folder.name,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          parent != null
                              ? '${folder.albumCount} albums • Inside "${parent.name}"'
                              : '${folder.albumCount} albums • Root level',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (folder.isHidden)
                    const Icon(Icons.visibility_off_rounded,
                        color: Colors.white70),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.adminFolderRename,
                        arguments: folder.id),
                    icon: const Icon(Icons.drive_file_rename_outline_rounded),
                    label: const Text('Rename'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.adminFolderMove,
                        arguments: folder.id),
                    icon: const Icon(Icons.swap_horiz_rounded),
                    label: const Text('Move'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.adminFolderSettings,
                    arguments: folder.id),
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Folder Settings'),
              ),
            ),

            // ----- Sub-folders (folder-in-folder nesting) -----
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Subfolders',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: context.textPrimary),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.adminFolderCreate,
                    arguments: folder.id,
                  ),
                  icon: const Icon(Icons.create_new_folder_rounded, size: 18),
                  label: const Text('New Subfolder'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (subfolders.isEmpty)
              const EmptyStateCard(message: 'No subfolders here yet.')
            else
              ...subfolders.map((child) {
                final childCount = folderState.folders
                    .where((f) => f.parentId == child.id)
                    .length;
                final cover = coverForFolder(
                  folderId: child.id,
                  allMedia: mediaState.allMedia,
                  allAlbums: albumState.allAlbums,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: FolderTile(
                    folder: child,
                    cover: cover,
                    childFolderCount: childCount,
                    onTap: () => Navigator.of(context).pushNamed(
                      AppRoutes.adminFolderDetails,
                      arguments: child.id,
                    ),
                  ),
                );
              }),

            // ----- Media filed directly in this folder -----
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Media in this folder',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: context.textPrimary),
                  ),
                ),
                if (directMedia.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MediaGridScreen(folderId: folder.id),
                      ),
                    ),
                    child: const Text('View all'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (directMedia.isEmpty)
              const EmptyStateCard(
                  message:
                      'No media added to this folder yet. Tap "Add Media" to upload some.')
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: directMedia.length > 9 ? 9 : directMedia.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, i) {
                  final MediaModel m = directMedia[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MediaGridScreen(folderId: folder.id),
                        ),
                      ),
                      child: MediaThumb(media: m),
                    ),
                  );
                },
              ),

            // ----- Albums filed under this folder -----
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Albums in this folder',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: context.textPrimary),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.adminAlbumCreate,
                    arguments: folder.id,
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add Album'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (relatedAlbums.isEmpty)
              const EmptyStateCard(
                  message: 'No albums filed under this folder yet.')
            else
              ...relatedAlbums.map(
                (a) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Material(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      onTap: () => Navigator.of(context).pushNamed(
                        AppRoutes.adminAlbumDetails,
                        arguments: a.id,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Row(
                          children: [
                            if (a.isFavorite) ...[
                              const Icon(Icons.favorite_rounded,
                                  size: 14, color: AppColors.accent),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ),
                            Text('${a.photoCount} photos',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: context.textMuted,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right_rounded,
                                size: 18, color: context.textMuted),
                          ],
                        ),
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

  Future<void> _queueFolderZip(
      BuildContext context, WidgetRef ref, FolderModel folder) async {
    try {
      await ref.read(zipJobsProvider.notifier).createJob(
            kind: 'zip_folder',
            targetId: folder.id,
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

