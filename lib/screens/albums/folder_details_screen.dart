import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../core/theme/theme_context.dart';

/// Admin-only Folder Details — reached by tapping a folder on
/// [FolderListScreen]. Fans out to Rename Folder, Move Folder and
/// Folder Settings, and previews the albums currently filed under it
/// (reusing [AlbumListController]'s existing folder filter).
class FolderDetailsScreen extends ConsumerWidget {
  final String folderId;

  const FolderDetailsScreen({super.key, required this.folderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folderState = ref.watch(folderProvider);
    final folder = folderState.folderById(folderId);

    if (folder == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Folder', showBack: true),
        body: Center(child: Text('Folder not found')),
      );
    }

    final parent = folder.parentId == null
        ? null
        : folderState.folderById(folder.parentId!);

    // Same real Album -> Folder link Albums List's "Filter folder" uses
    // (AlbumModel.folderId), so this preview always matches what's
    // actually filed here instead of a stand-in approximation.
    final albumState = ref.watch(albumProvider);
    final relatedAlbums = albumState.allAlbums
        .where((a) => a.folderId == folderId)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: CustomAppBar(title: folder.name, showBack: true),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.lg),
          children: [
            Container(
              padding: EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: folder.gradientArgb.map((a) => Color(a)).toList(),
                ),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_rounded, color: Colors.white, size: 32),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folder.name,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white),
                        ),
                        SizedBox(height: 4),
                        Text(
                          parent != null
                              ? '${folder.albumCount} albums • Inside "${parent.name}"'
                              : '${folder.albumCount} albums • Root level',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (folder.isHidden)
                    Icon(Icons.visibility_off_rounded, color: Colors.white70),
                ],
              ),
            ),
            SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.adminFolderRename,
                        arguments: folder.id),
                    icon: Icon(Icons.drive_file_rename_outline_rounded),
                    label: Text('Rename'),
                  ),
                ),
                SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.adminFolderMove,
                        arguments: folder.id),
                    icon: Icon(Icons.swap_horiz_rounded),
                    label: Text('Move'),
                  ),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.adminFolderSettings,
                    arguments: folder.id),
                icon: Icon(Icons.settings_rounded),
                label: Text('Folder Settings'),
              ),
            ),
            SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Albums in this folder',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text)),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.adminAlbumCreate,
                    arguments: folder.id,
                  ),
                  icon: Icon(Icons.add_rounded, size: 18),
                  label: Text('Add Album'),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.sm),
            if (relatedAlbums.isEmpty)
              const EmptyStateCard(
                  message: 'No albums filed under this folder yet.')
            else
              ...relatedAlbums.map(
                (a) => Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.sm),
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
                        padding: EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Row(
                          children: [
                            if (a.isFavorite) ...[
                              Icon(Icons.favorite_rounded,
                                  size: 14, color: AppColors.accent),
                              SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            Text('${a.photoCount} photos',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle),
                                    fontWeight: FontWeight.w600)),
                            SizedBox(width: 4),
                            Icon(Icons.chevron_right_rounded,
                                size: 18,
                                color: (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle)),
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
}
