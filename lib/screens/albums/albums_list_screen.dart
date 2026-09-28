import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/subscription_guard.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/face_search_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../widgets/common/custom_app_bar.dart';

import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/anchored_dropdown_field.dart';

import 'widgets/album_card.dart';
import '../media/media_grid_screen.dart' show MediaSearchArgs;

class AlbumsListScreen extends ConsumerStatefulWidget {
  const AlbumsListScreen({super.key});

  @override
  ConsumerState<AlbumsListScreen> createState() => _AlbumsListScreenState();
}

class _AlbumsListScreenState extends ConsumerState<AlbumsListScreen>
    with RouteAware {
  final _searchController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    ref.read(albumProvider).load();
  }

  @override
  void initState() {
    super.initState();
    // Keep initial in sync.
    final c = ref.read(albumProvider);
    _searchController.text = c.searchQuery;
  }

  Future<void> _confirmDeleteAlbum(AlbumModel album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Album?'),
        content: Text(
            'This will permanently remove "${album.name}" and its ${album.photoCount} photos. This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(albumProvider).deleteAlbum(album.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${album.name}" deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _moveAlbum(AlbumModel album, List<FolderModel> folders) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Text('Move to folder',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            ListTile(
              leading: Icon(Icons.block_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
              title: Text('No folder (unfile)'),
              trailing: album.folderId == null
                  ? Icon(Icons.check_rounded, color: AppColors.primary)
                  : null,
              onTap: () => Navigator.of(ctx).pop(_unfileSentinel),
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

    if (result == null || !mounted) return;
    final newFolderId =
        identical(result, _unfileSentinel) ? null : result as String;
    if (newFolderId == album.folderId) return;

    try {
      await ref.read(albumProvider).moveToFolder(album.id, newFolderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(newFolderId == null ? 'Album unfiled' : 'Album moved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Albums',
        showBack: false,
        actions: [
          IconButton(
            tooltip: 'Find by Face',
            icon: Icon(Icons.face_retouching_natural_rounded),
            onPressed: () {
              // Scopes the search to the studio's own library — mirrors
              // POST /faces/search (owner-only), same backend endpoint
              // the client-drawer's "Face Search" entry uses for
              // useClientGallery(), just pointed at the studio's own
              // photos instead of a client's shared galleries.
              ref.read(faceSearchProvider.notifier).useMyLibrary();
              Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
            },
          ),
          IconButton(
            tooltip: 'Manage Collections',
            icon: Icon(Icons.collections_bookmark_rounded),
            onPressed: () {
              Navigator.of(context).pushNamed(AppRoutes.collections);
            },
          ),
          IconButton(
            tooltip: 'Manage Folders',
            icon: Icon(Icons.folder_rounded),
            onPressed: () {
              Navigator.of(context).pushNamed(AppRoutes.adminFolderList);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'albums_list_fab',
        onPressed: () {
          requireActiveSubscription(context, ref, () {
            Navigator.of(context).pushNamed(AppRoutes.adminAlbumCreate);
          });
        },
        icon: Icon(Icons.add_rounded),
        label: Text('Create Album'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(albumProvider).load();
            await ref.read(mediaProvider).load();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Controls
                  Builder(
                    builder: (context) {
                      // simple inline controls without additional widget dependency
                      return Column(
                        children: [
                          TextField(
                            controller: _searchController,
                            onChanged: (v) {
                              albumState.setSearchQuery(v);
                            },
                            decoration: InputDecoration(
                              hintText: 'Search albums…',
                              prefixIcon: Icon(Icons.search_rounded),
                              suffixIcon: _searchController.text.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(Icons.clear_rounded),
                                      onPressed: () {
                                        _searchController.clear();
                                        albumState.setSearchQuery('');
                                      },
                                    )
                                  : null,
                            ),
                          ),
                          SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              Expanded(
                                child: AnchoredDropdownField<AlbumSortOption>(
                                  value: albumState.sortOption,
                                  items: const [
                                    DropdownMenuItem(
                                        value: AlbumSortOption.recent,
                                        child: Text('Recent')),
                                    DropdownMenuItem(
                                        value: AlbumSortOption.name,
                                        child: Text('Name')),
                                    DropdownMenuItem(
                                        value: AlbumSortOption.photoCount,
                                        child: Text('Photo count')),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    albumState.setSortOption(v);
                                  },
                                  decoration:
                                      const InputDecoration(labelText: 'Sort'),
                                ),
                              ),
                              SizedBox(width: AppSpacing.sm),
                              IconButton.filledTonal(
                                tooltip: albumState.isGrid
                                    ? 'Switch to list view'
                                    : 'Switch to grid view',
                                onPressed: albumState.toggleGridList,
                                icon: Icon(albumState.isGrid
                                    ? Icons.grid_view_rounded
                                    : Icons.view_list_rounded),
                              ),
                            ],
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Row(
                            children: [
                              Expanded(
                                child: folderState.isLoading
                                    ? SizedBox.shrink()
                                    : AnchoredDropdownField<String?>(
                                        // key forces a rebuild when the folder
                                        // list loads so the value stays in sync.
                                        key: ValueKey(
                                            'folder_filter_${folderState.folders.length}'),
                                        value: albumState.folderId,
                                        items: [
                                          const DropdownMenuItem<String?>(
                                            value: null,
                                            child: Text('All folders'),
                                          ),
                                          const DropdownMenuItem<String?>(
                                            value: kUnfiledFolderSentinel,
                                            child: Text('Unfiled (no folder)'),
                                          ),
                                          ...folderState.folders.map(
                                              (f) => DropdownMenuItem<String?>(
                                                    value: f.id,
                                                    child: Text(f.name),
                                                  )),
                                        ],
                                        onChanged: albumState.setFolder,
                                        decoration: const InputDecoration(
                                          labelText: 'Filter folder',
                                        ),
                                      ),
                              ),
                              SizedBox(width: AppSpacing.sm),
                              FilterChip(
                                label: Text('Favorites'),
                                selected: albumState.filterOption ==
                                    AlbumFilterOption.favorites,
                                onSelected: (v) {
                                  albumState.setFilterOption(v
                                      ? AlbumFilterOption.favorites
                                      : AlbumFilterOption.all);
                                },
                              ),
                            ],
                          ),
                          SizedBox(height: AppSpacing.lg),
                        ],
                      );
                    },
                  ),

                  if (albumState.isLoading || folderState.isLoading)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                      child: Center(
                          child: LoadingWidget(message: 'Loading albums…')),
                    )
                  else if (albumState.lastError != null &&
                      albumState.lastError!.trim().isNotEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                      child: Center(
                        child: EmptyStateCard(
                          icon: Icons.error_outline_rounded,
                          message: albumState.lastError!.trim(),
                        ),
                      ),
                    )
                  else if (albumState.filteredAlbums.isEmpty &&
                      albumState.folderId != null)
                    Center(
                      child: EmptyStateCard(
                        icon: Icons.photo_library_outlined,
                        message: 'No albums found in this folder.',
                      ),
                    )
                  else ...[
                    // ── Unfiled Uploads shortcut ──────────────────────
                    // Photos that were uploaded without picking an album
                    // live outside any album and are invisible in this
                    // list. Surface them as a tappable banner so studios
                    // can find them without needing the dashboard.
                    if (albumState.folderId == null)
                      Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.md),
                        child: InkWell(
                          onTap: () => Navigator.of(context).pushNamed(
                            AppRoutes.media,
                            arguments: const MediaSearchArgs(unfiledOnly: true),
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppColors.primary.withValues(alpha: 0.15),
                                  AppColors.secondary.withValues(alpha: 0.10)
                                ],
                              ),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border: Border.all(
                                color:
                                    AppColors.primary.withValues(alpha: 0.35),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.photo_library_rounded,
                                  color: AppColors.primary,
                                  size: 22,
                                ),
                                SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Unfiled Uploads',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                          color:
                                              (Theme.of(context).brightness ==
                                                      Brightness.dark
                                                  ? AppColors.textOnDark
                                                  : AppColors.text),
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Photos uploaded without an album',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color:
                                              (Theme.of(context).brightness ==
                                                      Brightness.dark
                                                  ? AppColors.subtitleOnDark
                                                  : AppColors.subtitle),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.subtitleOnDark
                                      : AppColors.subtitle),
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    if (albumState.filteredAlbums.isEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xxl),
                        child: Center(
                          child: EmptyStateCard(
                            icon: Icons.photo_library_outlined,
                            message:
                                'No albums found. Try adjusting filters/search.',
                          ),
                        ),
                      )
                    else if (albumState.isGrid)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: albumState.filteredAlbums.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 300,
                          mainAxisSpacing: AppSpacing.md,
                          crossAxisSpacing: AppSpacing.md,
                          childAspectRatio: 0.68,
                        ),
                        itemBuilder: (context, i) {
                          final album = albumState.filteredAlbums[i];
                          return _AnimatedAlbumTile(
                            index: i,
                            child: AlbumCard(
                              album: album,
                              onToggleFavorite: () =>
                                  albumState.toggleFavorite(album.id),
                              onTap: () => Navigator.of(context).pushNamed(
                                AppRoutes.adminAlbumDetails,
                                arguments: album.id,
                              ),
                              onEdit: () => Navigator.of(context).pushNamed(
                                AppRoutes.adminAlbumEdit,
                                arguments: album.id,
                              ),
                              onMove: () =>
                                  _moveAlbum(album, folderState.folders),
                              onDelete: () => _confirmDeleteAlbum(album),
                            ),
                          );
                        },
                      )
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: albumState.filteredAlbums.length,
                        separatorBuilder: (_, __) =>
                            SizedBox(height: AppSpacing.sm),
                        itemBuilder: (context, i) {
                          final album = albumState.filteredAlbums[i];
                          return _AnimatedAlbumTile(
                            index: i,
                            child: AlbumCard(
                              album: album,
                              onToggleFavorite: () =>
                                  albumState.toggleFavorite(album.id),
                              onTap: () => Navigator.of(context).pushNamed(
                                AppRoutes.adminAlbumDetails,
                                arguments: album.id,
                              ),
                              onEdit: () => Navigator.of(context).pushNamed(
                                AppRoutes.adminAlbumEdit,
                                arguments: album.id,
                              ),
                              onMove: () =>
                                  _moveAlbum(album, folderState.folders),
                              onDelete: () => _confirmDeleteAlbum(album),
                              compact: true,
                            ),
                          );
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Distinguishes "user picked No folder" from "sheet dismissed with no
/// selection" in [_AlbumsListScreenState._moveAlbum].
const Object _unfileSentinel = _UnfileSentinelToken();

class _UnfileSentinelToken {
  const _UnfileSentinelToken();
}

/// Light staggered fade+rise entrance so newly-loaded/created albums
/// don't just pop onto the grid — each tile's delay is capped so a long
/// list doesn't feel sluggish to finish animating in.
class _AnimatedAlbumTile extends StatefulWidget {
  const _AnimatedAlbumTile({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_AnimatedAlbumTile> createState() => _AnimatedAlbumTileState();
}

class _AnimatedAlbumTileState extends State<_AnimatedAlbumTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.medium,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    final delayMs = (widget.index.clamp(0, 8)) * 40;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
