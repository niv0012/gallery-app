import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/folder_model.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../core/theme/theme_context.dart';

/// File-browser style entry point for a folder's contents.
///
/// [folderId] is null for the root level ("My Files"). Passing a real
/// folder id shows that folder's own name in the app bar instead.
///
/// Sub-folders are read straight off [FolderFacade.childrenOf], which
/// filters the already-fetched folders list (backed by the real
/// `ApiFolderRepository` / folders endpoint via [folderProvider]) down to
/// `parentId == folderId` — no separate fetch call needed. Files/albums
/// inside the folder still need wiring up in a later sub-task; for now
/// the grid only renders sub-folder tiles.
class FolderExplorerScreen extends ConsumerStatefulWidget {
  const FolderExplorerScreen({super.key, this.folderId});

  /// Null = root ("My Files"). Otherwise the id of the folder being browsed.
  final String? folderId;

  @override
  ConsumerState<FolderExplorerScreen> createState() =>
      _FolderExplorerScreenState();
}

class _FolderExplorerScreenState extends ConsumerState<FolderExplorerScreen> {
  @override
  Widget build(BuildContext context) {
    final folderId = widget.folderId;
    final folderFacade = ref.watch(folderProvider);

    final title = folderId == null
        ? 'My Files'
        : folderFacade.folderById(folderId)?.name ?? 'My Files';

    final subfolders = folderFacade.childrenOf(folderId);

    return Scaffold(
      appBar: CustomAppBar(title: title, showBack: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: folderFacade.isLoading
              ? const Center(child: LoadingWidget(message: 'Loading folders…'))
              : subfolders.isEmpty
                  ? const Center(
                      child: EmptyStateCard(
                        icon: Icons.folder_off_rounded,
                        message: 'No folders here yet.',
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: AppSpacing.md,
                        mainAxisSpacing: AppSpacing.md,
                        childAspectRatio: 1,
                      ),
                      itemCount: subfolders.length,
                      itemBuilder: (context, index) {
                        final folder = subfolders[index];
                        return _FolderGridTile(
                          folder: folder,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  FolderExplorerScreen(folderId: folder.id),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}

/// Grid-style folder card — icon, name, item count. Distinct from
/// [FolderTile] (the row-style widget used by the admin Folder List /
/// Folder Details screens) since this explorer lays folders out as a
/// grid rather than a list.
class _FolderGridTile extends StatelessWidget {
  const _FolderGridTile({required this.folder, required this.onTap});

  final FolderModel folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: context.surfaceColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: folder.gradientArgb.map((a) => Color(a)).toList(),
                ),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(Icons.folder_rounded, color: Colors.white),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary),
            ),
            const SizedBox(height: 2),
            Text(
              '${folder.albumCount} ${folder.albumCount == 1 ? 'item' : 'items'}',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
