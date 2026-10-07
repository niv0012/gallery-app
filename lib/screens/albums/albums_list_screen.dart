import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/utils/responsive_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/subscription_guard.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/face_search_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../providers/folder_explorer_provider.dart';
import '../../widgets/common/custom_app_bar.dart';

import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/compact_anchored_dropdown.dart';
import '../../widgets/folders/safe_delete_dialog.dart';

import 'widgets/album_card.dart';
import '../media/media_grid_screen.dart' show MediaSearchArgs;
import '../folders/folder_explorer_screen.dart';

class AlbumsListScreen extends ConsumerStatefulWidget {
  const AlbumsListScreen({super.key});

  @override
  ConsumerState<AlbumsListScreen> createState() => _AlbumsListScreenState();
}

class _AlbumsListScreenState extends ConsumerState<AlbumsListScreen>
    with RouteAware {
  final _searchController = TextEditingController();
  bool _showFolders = false;

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
    final albumRepo = ref.read(albumRepositoryProvider);
    final mode = await showSafeDeleteDialog(
      context: context,
      itemName: album.name,
      getPreview: (mode) => albumRepo.previewDeleteAlbum(album.id, mode: mode),
    );
    if (mode == null || !mounted) return;

    try {
      await ref.read(albumProvider).deleteAlbum(album.id, mode: mode);
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

  Widget _buildTab(BuildContext context, {required String title, required bool isSelected, required VoidCallback onTap}) {
    final color = isSelected ? const Color(0xFF8A5FFC) : (Theme.of(context).brightness == Brightness.dark ? Colors.white54 : AppColors.subtitle);
    
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.only(bottom: 12, top: 4, left: 4, right: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? const Color(0xFF8A5FFC) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            color: color,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 14,
            letterSpacing: -0.2,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
          child: Text(title),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Gallery',
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white12 : Colors.grey.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  _buildTab(context, title: 'Albums', isSelected: !_showFolders, onTap: () => setState(() => _showFolders = false)),
                  const SizedBox(width: 24),
                  _buildTab(context, title: 'Folders', isSelected: _showFolders, onTap: () => setState(() => _showFolders = true)),
                ],
              ),
            ),
          ),
        ),
        showBack: false,
        actions: [
          IconButton(
            tooltip: 'Find by Face',
            icon: const Icon(Icons.face_retouching_natural_rounded),
            onPressed: () {
              ref.read(faceSearchProvider.notifier).useMyLibrary();
              Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
            },
          ),
        ],
      ),
      floatingActionButton: _showFolders 
          ? null
          : FloatingActionButton.extended(
              heroTag: 'albums_list_fab',
              onPressed: () {
                requireActiveSubscription(context, ref, () {
                  Navigator.of(context).pushNamed(AppRoutes.adminAlbumCreate);
                });
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create Album'),
            ),
      body: _showFolders
          ? const FolderExplorerScreen(isEmbedded: true)
          : SafeArea(
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
                      final isDark = Theme.of(context).brightness == Brightness.dark;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                            Container(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? AppColors.darkSurfaceRaised : Colors.white,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: isDark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: CompactAnchoredDropdown<AlbumSortOption>(
                                value: albumState.sortOption,
                                items: const [
                                  DropdownMenuItem(
                                    value: AlbumSortOption.recent,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.access_time_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Recent', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: AlbumSortOption.name,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.sort_by_alpha_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Name', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: AlbumSortOption.photoCount,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.photo_library_outlined, size: 16), SizedBox(width: 8), Flexible(child: Text('Photos', overflow: TextOverflow.ellipsis))]),
                                  ),
                                ],
                                onChanged: (v) => albumState.setSortOption(v),
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: isDark ? Colors.white : AppColors.text),
                              ),
                            ),
                            if (!folderState.isLoading)
                              Padding(
                                padding: const EdgeInsets.only(left: AppSpacing.sm),
                                child: Container(
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.4),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isDark ? AppColors.darkSurfaceRaised : Colors.white,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: isDark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: CompactAnchoredDropdown<String?>(
                                  key: ValueKey('folder_filter_${folderState.folders.length}'),
                                  value: albumState.folderId,
                                  items: [
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.grid_view_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('All Albums', overflow: TextOverflow.ellipsis))]),
                                    ),
                                    const DropdownMenuItem<String?>(
                                      value: kUnfiledFolderSentinel,
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.block_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Unfiled', overflow: TextOverflow.ellipsis))]),
                                    ),
                                    ...folderState.folders.map(
                                      (f) => DropdownMenuItem<String?>(
                                        value: f.id,
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.folder_outlined, size: 16), SizedBox(width: 8), Flexible(child: Text(f.name, overflow: TextOverflow.ellipsis))]),
                                      ),
                                    ),
                                  ],
                                  onChanged: albumState.setFolder,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: isDark ? Colors.white : AppColors.text),
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Container(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? AppColors.darkSurfaceRaised : Colors.white,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: isDark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: CompactAnchoredDropdown<ExplorerViewMode>(
                                value: albumState.viewMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: ExplorerViewMode.gridLarge,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.grid_view_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Large icons', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: ExplorerViewMode.gridMedium,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.grid_on_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Medium icons', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: ExplorerViewMode.gridSmall,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.apps_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Small icons', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: ExplorerViewMode.list,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.list_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('List', overflow: TextOverflow.ellipsis))]),
                                  ),
                                  DropdownMenuItem(
                                    value: ExplorerViewMode.details,
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.view_list_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text('Details', overflow: TextOverflow.ellipsis))]),
                                  ),
                                ],
                                onChanged: (v) => albumState.setViewMode(v),
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: isDark ? Colors.white : AppColors.text),
                              ),
                            ),
                          ],
                        ),
                      ),
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
                    else if (albumState.viewMode == ExplorerViewMode.gridLarge || albumState.viewMode == ExplorerViewMode.gridMedium || albumState.viewMode == ExplorerViewMode.gridSmall)
                      LayoutBuilder(builder: (context, box) {
                        final mode = albumState.viewMode;
                        // Phones / native: unchanged 2 / 3 / 6 columns.
                        // Web (wide): fit as many tiles as the icon size
                        // allows, centered with a max width, so "Large
                        // icons" is no longer 2 giant tiles.
                        final wideWeb = kIsWeb &&
                            MediaQuery.of(context).size.width >=
                                ResponsiveUtils.mobileBreakpoint;
                        final usable = box.maxWidth > ResponsiveUtils.galleryMaxWidth
                            ? ResponsiveUtils.galleryMaxWidth
                            : box.maxWidth;
                        final columns = wideWeb
                            ? ResponsiveUtils.columnsForTileWidth(
                                usable,
                                mode == ExplorerViewMode.gridLarge
                                    ? ResponsiveUtils.tileLarge
                                    : (mode == ExplorerViewMode.gridMedium
                                        ? ResponsiveUtils.tileMedium
                                        : ResponsiveUtils.tileSmall))
                            : (mode == ExplorerViewMode.gridLarge
                                ? 2
                                : (mode == ExplorerViewMode.gridMedium ? 3 : 6));
                        return Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxWidth: wideWeb
                                    ? ResponsiveUtils.galleryMaxWidth
                                    : double.infinity),
                            child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: albumState.filteredAlbums.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
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
                            ),
                          ),
                        );
                      })
                    else if (albumState.viewMode == ExplorerViewMode.list)
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
                      )
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          showCheckboxColumn: false,
                          columns: const [
                            DataColumn(label: Text('Name')),
                            DataColumn(label: Text('Items')),
                            DataColumn(label: Text('Updated')),
                          ],
                          rows: albumState.filteredAlbums.map((album) {
                            return DataRow(
                              onSelectChanged: (_) => Navigator.of(context).pushNamed(AppRoutes.adminAlbumDetails, arguments: album.id),
                              cells: [
                                DataCell(
                                  Row(
                                    children: [
                                      const Icon(Icons.photo_album_rounded, size: 18),
                                      const SizedBox(width: 8),
                                      Text(album.name),
                                    ],
                                  ),
                                ),
                                DataCell(Text('${album.photoCount + album.videoCount}')),
                                DataCell(Text(album.updatedAt.toLocal().toString().split(' ')[0])),
                              ],
                            );
                          }).toList(growable: false),
                        ),
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
