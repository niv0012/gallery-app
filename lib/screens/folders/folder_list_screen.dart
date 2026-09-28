import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/utils/folder_cover_utils.dart';
import '../../core/utils/subscription_guard.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/folder_tile.dart';
import '../../widgets/common/loading_widget.dart';

/// Admin-only Folder List — reached from the Albums List app bar and
/// from Album Details. Lets the studio owner browse, create and drill
/// into folders.
///
/// Shows root-level folders only (`parentId == null`) — tapping one
/// opens [FolderDetailsScreen], which is where its sub-folders live and
/// can be drilled into recursively, so folder-in-folder nesting reads
/// as a normal file-browser hierarchy instead of one long flat list.
class FolderListScreen extends ConsumerStatefulWidget {
  const FolderListScreen({super.key});

  @override
  ConsumerState<FolderListScreen> createState() => _FolderListScreenState();
}

class _FolderListScreenState extends ConsumerState<FolderListScreen>
    with RouteAware {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _refresh();
  }

  @override
  void initState() {
    super.initState();
    // Always do a fresh fetch when this screen opens so the list is
    // never stale (e.g. folders created from another screen, or after
    // a network error during a previous visit).
    Future.microtask(() {
      if (mounted) ref.read(folderProvider).load();
    });
  }

  Future<void> _refresh() => ref.read(folderProvider).load();

  @override
  Widget build(BuildContext context) {
    final folderState = ref.watch(folderProvider);
    final mediaState = ref.watch(mediaProvider);
    final albumState = ref.watch(albumProvider);

    final rootFolders =
        folderState.folders.where((f) => f.parentId == null).toList();
    final hasError = folderState.lastError != null && rootFolders.isEmpty;

    Widget body;

    if (folderState.isLoading && rootFolders.isEmpty) {
      body = const Center(child: LoadingWidget(message: 'Loading folders…'));
    } else if (hasError) {
      // API call failed — show a retry button so the user isn't stuck.
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Could not load folders',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                folderState.lastError ?? '',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (rootFolders.isEmpty) {
      body = const Center(
        child: EmptyStateCard(
          icon: Icons.folder_off_rounded,
          message: 'No folders yet. Tap "Create Folder" to add one.',
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: rootFolders.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (context, i) {
            final folder = rootFolders[i];
            final childCount = folderState.folders
                .where((f) => f.parentId == folder.id)
                .length;
            final cover = coverForFolder(
              folderId: folder.id,
              allMedia: mediaState.allMedia,
              allAlbums: albumState.allAlbums,
            );
            return FolderTile(
              folder: folder,
              cover: cover,
              childFolderCount: childCount,
              onTap: () => Navigator.of(context).pushNamed(
                AppRoutes.adminFolderDetails,
                arguments: folder.id,
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: const CustomAppBar(title: 'Folders', showBack: true),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'folder_list_fab',
        onPressed: () {
          requireActiveSubscription(context, ref, () {
            Navigator.of(context).pushNamed(AppRoutes.adminFolderCreate);
          });
        },
        icon: const Icon(Icons.create_new_folder_rounded),
        label: const Text('Create Folder'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: body,
        ),
      ),
    );
  }
}
