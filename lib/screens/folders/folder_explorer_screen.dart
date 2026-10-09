import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/utils/responsive_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';
import '../../l10n/app_localizations.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';
import '../../models/media_model.dart';
import '../../models/delete_preview_model.dart';
import '../../providers/folder_explorer_provider.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/delete_confirmation_dialog.dart';
import '../../widgets/common/pinch_zoom_grid.dart';
import '../../widgets/common/snackbar_helper.dart';
import '../../widgets/common/compact_anchored_dropdown.dart';
import '../../providers/album_provider.dart';
import '../../providers/auth_providers.dart';
import '../../providers/face_search_provider.dart';
import '../../widgets/media/face_search_actions.dart';
import '../media/media_batch_workflows.dart';
import '../media/media_details_screen.dart';

import '../albums/albums_list_screen.dart';
import 'folder_details_screen.dart';

import '../../providers/media_provider.dart';
import '../../widgets/media/watermark_overlay.dart';
import '../../providers/zip_job_provider.dart';
import '../../widgets/folders/safe_delete_dialog.dart';

class FolderExplorerScreen extends ConsumerStatefulWidget {
  const FolderExplorerScreen({super.key, this.folderId, this.isEmbedded = false});

  final String? folderId;
  final bool isEmbedded;

  @override
  ConsumerState<FolderExplorerScreen> createState() => _FolderExplorerScreenState();
}

class _FolderExplorerScreenState extends ConsumerState<FolderExplorerScreen> {
  final DateFormat _dateFormat = DateFormat.yMMMd();
  final Set<String> _selectedIds = {};
  int? _gridColumns;

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final folderId = widget.folderId;
    final folderFacade = ref.watch(folderProvider);
    final contentsAsync = ref.watch(folderContentsProvider(folderId ?? 'root'));
    final authState = ref.watch(authStateProvider);
    final prefs = ref.watch(folderExplorerPrefsProvider);

    final title = folderId == null
        ? l10n.folderExplorerMyFiles
        : folderFacade.folderById(folderId)?.name ?? l10n.folderExplorerMyFiles;

    final List<ExplorerItem>? items = contentsAsync.valueOrNull != null
        ? _combineAndSortItems(
            [...contentsAsync.value!.folders],
            [...contentsAsync.value!.albums],
            [...contentsAsync.value!.media],
            prefs,
          )
        : null;

    final bodyWidget = SafeArea(
      child: contentsAsync.when(
        data: (contents) {
          if (items == null || items.isEmpty) {
            return Center(
              child: EmptyStateCard(
                icon: Icons.folder_off_rounded,
                message: l10n.folderExplorerEmpty,
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(folderContentsProvider(folderId ?? 'root'));
              try {
                await ref.read(folderContentsProvider(folderId ?? 'root').future);
              } catch (_) {}
            },
            child: Column(
              children: [
                if (!widget.isEmbedded) _buildBreadcrumb(l10n, folderFacade, folderId),
                _buildControls(l10n, prefs),
                Expanded(
                  child: switch (prefs.viewMode) {
                    ExplorerViewMode.gridLarge => _buildGridView(
                        l10n: l10n,
                        items: items,
                        overrideColumns: 2,
                      ),
                    ExplorerViewMode.gridMedium => _buildGridView(
                        l10n: l10n,
                        items: items,
                        overrideColumns: 4,
                      ),
                    ExplorerViewMode.gridSmall => _buildGridView(
                        l10n: l10n,
                        items: items,
                        overrideColumns: 6,
                      ),
                    ExplorerViewMode.list => _buildListView(
                        l10n: l10n,
                        items: items,
                      ),
                    ExplorerViewMode.details => _buildDetailsView(
                        l10n: l10n,
                        items: items,
                      ),
                  },
                ),
              ],
            ),
          );
        },
        loading: () => items != null
            // Show stale data + spinner overlay while reloading
            ? Stack(
                children: [
                  Column(
                    children: [
                      if (!widget.isEmbedded) _buildBreadcrumb(l10n, folderFacade, folderId),
                      _buildControls(l10n, prefs),
                      Expanded(
                        child: switch (prefs.viewMode) {
                          ExplorerViewMode.gridLarge => _buildGridView(l10n: l10n, items: items, overrideColumns: 2),
                          ExplorerViewMode.gridMedium => _buildGridView(l10n: l10n, items: items, overrideColumns: 4),
                          ExplorerViewMode.gridSmall => _buildGridView(l10n: l10n, items: items, overrideColumns: 6),
                          ExplorerViewMode.list => _buildListView(l10n: l10n, items: items),
                          ExplorerViewMode.details => _buildDetailsView(l10n: l10n, items: items),
                        },
                      ),
                    ],
                  ),
                  const Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(),
                  ),
                ],
              )
            : Center(child: LoadingWidget(message: l10n.folderExplorerLoading)),
        error: (e, st) => Center(child: Text('$e')),
      ),
    );

    if (widget.isEmbedded) {
      return Stack(
        children: [
          bodyWidget,
          if (!_isSelectionMode)
            Positioned(
              bottom: 16,
              right: 16,
              child: PopupMenuButton<int>(
                tooltip: 'Create',
                offset: const Offset(0, -120),
                child: FloatingActionButton(
                  onPressed: null,
                  child: const Icon(Icons.add_rounded),
                ),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 0,
                    child: Row(children: [Icon(Icons.create_new_folder_rounded), SizedBox(width: 8), Text('New folder')]),
                  ),
                  PopupMenuItem(
                    value: 1,
                    child: Row(children: [Icon(Icons.photo_album_rounded), SizedBox(width: 8), Text('New album')]),
                  ),
                  PopupMenuItem(
                    value: 2,
                    child: Row(children: [Icon(Icons.upload_rounded), SizedBox(width: 8), Text('Upload here')]),
                  ),
                ],
                onSelected: (value) {
                  if (value == 0) {
                    Navigator.of(context)
                        .pushNamed(AppRoutes.adminFolderCreate, arguments: folderId)
                        .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                  } else if (value == 1) {
                    Navigator.of(context)
                        .pushNamed(AppRoutes.adminAlbumCreate, arguments: folderId)
                        .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                  } else if (value == 2) {
                    Navigator.of(context)
                        .pushNamed(AppRoutes.newUpload, arguments: {'folderId': folderId})
                        .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                  }
                },
              ),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: CustomAppBar(
        title: _isSelectionMode ? '${_selectedIds.length} Selected' : title,
        showBack: folderId != null,
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : null,
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: 'Move',
                  icon: const Icon(Icons.drive_file_move_rounded),
                  onPressed: () {
                    if (items != null) _handleBulkMove(items);
                  },
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_rounded),
                  onPressed: () {
                    if (items != null) _handleBulkDelete(items);
                  },
                ),
              ]
            : [
                // Scoped (this folder) + global face search. When embedded
                // in the Albums screen's "Folders" tab that screen's own
                // app bar already carries the global icon.
                if (!widget.isEmbedded)
                  ...faceSearchActions(
                    context,
                    ref,
                    folderId: folderId,
                    scopeLabel: title,
                  ),
                if (folderId != null)
                  IconButton(
                    icon: const Icon(Icons.settings),
                    onPressed: () {
                      final folder = folderFacade.folderById(folderId);
                      if (folder != null) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => FolderDetailsScreen(folderId: folder.id),
                          ),
                        );
                      }
                    },
                  ),
                IconButton(
                  tooltip: l10n.folderExplorerManageFolders,
                  icon: const Icon(Icons.folder_rounded),
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.adminFolderList),
                ),
                PopupMenuButton<_ExplorerMenuAction>(
                  tooltip: l10n.folderExplorerMenu,
                  onSelected: (action) {
                    if (action == _ExplorerMenuAction.allAlbums) {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AlbumsListScreen()),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _ExplorerMenuAction.allAlbums,
                      child: Text(l10n.folderExplorerAllAlbums),
                    ),
                  ],
                ),
              ],
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : PopupMenuButton<int>(
              tooltip: 'Create',
              offset: const Offset(0, -120),
              child: FloatingActionButton(
                onPressed: null,
                child: const Icon(Icons.add_rounded),
              ),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 0,
                  child: Row(children: [Icon(Icons.create_new_folder_rounded), SizedBox(width: 8), Text('New folder')]),
                ),
                PopupMenuItem(
                  value: 1,
                  child: Row(children: [Icon(Icons.photo_album_rounded), SizedBox(width: 8), Text('New album')]),
                ),
                PopupMenuItem(
                  value: 2,
                  child: Row(children: [Icon(Icons.upload_rounded), SizedBox(width: 8), Text('Upload here')]),
                ),
              ],
              onSelected: (value) {
                if (value == 0) {
                  Navigator.of(context)
                      .pushNamed(AppRoutes.adminFolderCreate, arguments: folderId)
                      .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                } else if (value == 1) {
                  Navigator.of(context)
                      .pushNamed(AppRoutes.adminAlbumCreate, arguments: folderId)
                      .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                } else if (value == 2) {
                  Navigator.of(context)
                      .pushNamed(AppRoutes.newUpload, arguments: {'folderId': folderId})
                      .then((_) => ref.invalidate(folderContentsProvider(folderId ?? 'root')));
                }
              },
            ),
      body: bodyWidget,
    );
  }

  Widget _buildBreadcrumb(
    AppLocalizations l10n,
    FolderFacade folderFacade,
    String? folderId,
  ) {
    final crumbs = folderId == null ? const <FolderModel>[] : folderFacade.breadcrumbFor(folderId);
    final textStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle);
    final activeStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : AppColors.text);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.black26 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  if (folderId != null) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const FolderExplorerScreen()),
                      (route) => route.isFirst,
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.home_rounded, size: 16, color: crumbs.isEmpty ? activeStyle.color : textStyle.color),
                      const SizedBox(width: 4),
                      Text(l10n.home, style: crumbs.isEmpty ? activeStyle : textStyle),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < crumbs.length; i++) ...[
                Icon(Icons.chevron_right_rounded, size: 16, color: textStyle.color!.withValues(alpha: 0.5)),
                if (i == crumbs.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(crumbs[i].name, style: activeStyle),
                  )
                else
                  InkWell(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => FolderExplorerScreen(folderId: crumbs[i].id)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(crumbs[i].name, style: textStyle),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(AppLocalizations l10n, FolderExplorerPrefs prefs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: CompactAnchoredDropdown<ExplorerViewMode>(
                value: prefs.viewMode,
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
                onChanged: (v) => ref.read(folderExplorerPrefsProvider.notifier).setViewMode(v),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : AppColors.text),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CompactAnchoredDropdown<ExplorerSortField>(
                    value: prefs.sortField,
                    onChanged: (value) {
                      ref.read(folderExplorerPrefsProvider.notifier).setSort(value, prefs.ascending);
                    },
                    items: [
                      DropdownMenuItem(
                        value: ExplorerSortField.name,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.sort_by_alpha_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text(l10n.folderExplorerSortByName, overflow: TextOverflow.ellipsis))]),
                      ),
                      DropdownMenuItem(
                        value: ExplorerSortField.date,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.calendar_today_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text(l10n.folderExplorerSortByDate, overflow: TextOverflow.ellipsis))]),
                      ),
                      DropdownMenuItem(
                        value: ExplorerSortField.dateCreated,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.edit_calendar_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text(l10n.folderExplorerSortByDateCreated, overflow: TextOverflow.ellipsis))]),
                      ),
                      DropdownMenuItem(
                        value: ExplorerSortField.size,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.data_usage_rounded, size: 16), SizedBox(width: 8), Flexible(child: Text(l10n.folderExplorerSortBySize, overflow: TextOverflow.ellipsis))]),
                      ),
                    ],
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : AppColors.text),
                  ),
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : Colors.grey.withValues(alpha: 0.3),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      ref.read(folderExplorerPrefsProvider.notifier).setSort(
                            prefs.sortField,
                            !prefs.ascending,
                          );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        prefs.ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                        size: 16,
                        color: Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => ref.read(folderExplorerPrefsProvider.notifier).setFoldersFirst(!prefs.foldersFirst),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: prefs.foldersFirst
                      ? AppColors.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.1)
                      : (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: prefs.foldersFirst
                        ? AppColors.primary.withValues(alpha: 0.5)
                        : (Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.grey.withValues(alpha: 0.15)),
                  ),
                  boxShadow: [
                    if (!prefs.foldersFirst)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.03),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_special_rounded,
                      size: 16,
                      color: prefs.foldersFirst
                          ? AppColors.primary
                          : (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Folders First',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: prefs.foldersFirst
                            ? AppColors.primary
                            : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridView({
    required AppLocalizations l10n,
    required List<ExplorerItem> items,
    int? overrideColumns,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    int crossAxisCount = overrideColumns ?? _gridColumns ?? 2;
    if (overrideColumns == null && _gridColumns == null) {
      if (screenWidth > 800) {
        crossAxisCount = 4;
      } else if (screenWidth > 600) {
        crossAxisCount = 3;
      }
    }

    // WEB / wide windows: size by tile width so Large / Medium / Small
    // icons stay proportionate at any browser width (an explicit pinch
    // override still wins). Phones & native apps keep the old counts.
    final bool responsiveWeb = kIsWeb && screenWidth >= ResponsiveUtils.mobileBreakpoint;
    final double webTargetTile = switch (overrideColumns) {
      2 => ResponsiveUtils.tileLarge,
      6 => ResponsiveUtils.tileSmall,
      _ => ResponsiveUtils.tileMedium,
    };

    return LayoutBuilder(builder: (context, box) {
    final usable = (box.maxWidth > ResponsiveUtils.galleryMaxWidth
            ? ResponsiveUtils.galleryMaxWidth
            : box.maxWidth) -
        AppSpacing.md * 2;
    final effectiveColumns = (responsiveWeb && _gridColumns == null)
        ? ResponsiveUtils.columnsForTileWidth(usable, webTargetTile)
        : crossAxisCount;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: responsiveWeb ? ResponsiveUtils.galleryMaxWidth : double.infinity),
        child: PinchZoomGrid(
      onZoomIn: () {
        if (effectiveColumns > 1) setState(() => _gridColumns = effectiveColumns - 1);
      },
      onZoomOut: () {
        if (effectiveColumns < 12) setState(() => _gridColumns = effectiveColumns + 1);
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: effectiveColumns,
                crossAxisSpacing: AppSpacing.md,
                mainAxisSpacing: AppSpacing.md,
                childAspectRatio: 1,
              ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = items[index];
                switch (item) {
                  case FolderItem():
                    return _FolderGridTile(
                      folder: item.folder,
                      isSelected: _selectedIds.contains(item.id),
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleSelection(item.id);
                        } else {
                          _openFolder(item.id);
                        }
                      },
                      onLongPress: () => _toggleSelection(item.id),
                      onAction: (action) => _handleFolderAction(item.folder, action),
                    );
                  case AlbumItem():
                    return _AlbumGridTile(
                      album: item.album,
                      isSelected: _selectedIds.contains(item.id),
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleSelection(item.id);
                        } else {
                          _openAlbum(item.id);
                        }
                      },
                      onLongPress: () => _toggleSelection(item.id),
                      onAction: (action) => _handleAlbumAction(item.album, action),
                    );
                  case MediaItem():
                    return _MediaGridTile(
                      media: item.media,
                      isSelected: _selectedIds.contains(item.id),
                      showWatermark: (widget.folderId == null ? null : ref.read(folderProvider).folderById(widget.folderId!))?.showWatermark ?? false,
                      watermarkUrl: ref.read(authStateProvider).user?.avatarUrl,
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleSelection(item.id);
                        } else {
                          final mediaIds = items.whereType<MediaItem>().map((i) => i.media.id).toList(growable: false);
                          Navigator.of(context).pushNamed(AppRoutes.mediaDetails, arguments: MediaDetailsArgs(
                            mediaId: item.media.id, 
                            mediaIds: mediaIds,
                            showWatermark: (widget.folderId == null ? null : ref.read(folderProvider).folderById(widget.folderId!))?.showWatermark ?? false,
                            watermarkUrl: ref.read(authStateProvider).user?.avatarUrl,
                          ));
                        }
                      },
                      onLongPress: () => _toggleSelection(item.id),
                      onAction: (action) => _handleMediaAction(item.media, action),
                    );
                }
              },
              childCount: items.length,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
      ],
    ),
    ),
      ),
    );
    });
  }

  Widget _buildListView({
    required AppLocalizations l10n,
    required List<ExplorerItem> items,
  }) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        switch (item) {
          case FolderItem():
            final f = item.folder;
            return ListTile(
              selected: _selectedIds.contains(f.id),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_rounded),
              title: Text(f.name),
              subtitle: Text('${f.albumCount + f.photoCount + f.videoCount} ${l10n.folderExplorerItems}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (f.hasShareLink) const Icon(Icons.link_rounded, size: 18, color: AppColors.primary),
                  if (f.hasShareLink && f.isHidden) const SizedBox(width: 8),
                  if (f.isHidden) const Icon(Icons.visibility_off_rounded, size: 18),
                  PopupMenuButton<_FolderAction>(
                    onSelected: (action) => _handleFolderAction(f, action),
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: _FolderAction.rename, child: Text('Rename')),
                      const PopupMenuItem(value: _FolderAction.move, child: Text('Move')),
                      const PopupMenuItem(value: _FolderAction.hide, child: Text('Hide')),
                      const PopupMenuItem(value: _FolderAction.share, child: Text('Share')),
                      const PopupMenuItem(value: _FolderAction.download, child: Text('Download')),
                      PopupMenuItem(
                        value: _FolderAction.watermark, 
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Watermark'),
                            if (f.showWatermark == true) const Icon(Icons.check, size: 16, color: AppColors.primary),
                          ],
                        ),
                      ),
                      const PopupMenuItem(value: _FolderAction.faceSearch, child: Text('Face Search')),
                      const PopupMenuItem(value: _FolderAction.delete, child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(f.id);
                } else {
                  _openFolder(f.id);
                }
              },
              onLongPress: () => _toggleSelection(f.id),
            );
          case AlbumItem():
            final a = item.album;
            return ListTile(
              selected: _selectedIds.contains(a.id),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_album_rounded),
              title: Text(a.name),
              subtitle: Text('${a.photoCount + a.videoCount}'),
              trailing: PopupMenuButton<_AlbumAction>(
                onSelected: (action) => _handleAlbumAction(a, action),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: _AlbumAction.rename, child: Text('Rename')),
                  const PopupMenuItem(value: _AlbumAction.move, child: Text('Move')),
                  const PopupMenuItem(value: _AlbumAction.share, child: Text('Share')),
                  const PopupMenuItem(value: _AlbumAction.download, child: Text('Download')),
                  const PopupMenuItem(value: _AlbumAction.faceSearch, child: Text('Face Search')),
                  const PopupMenuItem(value: _AlbumAction.delete, child: Text('Delete')),
                ],
              ),
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(a.id);
                } else {
                  _openAlbum(a.id);
                }
              },
              onLongPress: () => _toggleSelection(a.id),
            );
          case MediaItem():
            final m = item.media;
            return ListTile(
              selected: _selectedIds.contains(m.id),
              contentPadding: EdgeInsets.zero,
              leading: Icon(m.type == MediaType.video ? Icons.play_circle_fill_rounded : Icons.image_rounded),
              title: Text(m.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(m.type == MediaType.video && m.duration != null 
                  ? '${m.size} B • ${m.duration!.inMinutes}:${m.duration!.inSeconds.remainder(60).toString().padLeft(2, '0')}' 
                  : '${m.size} B'),
              trailing: PopupMenuButton<_MediaAction>(
                onSelected: (action) => _handleMediaAction(m, action),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: _MediaAction.open, child: Text('Open')),
                  const PopupMenuItem(value: _MediaAction.move, child: Text('Move')),
                  const PopupMenuItem(value: _MediaAction.delete, child: Text('Delete')),
                ],
              ),
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(m.id);
                } else {
                  final mediaIds = items.whereType<MediaItem>().map((i) => i.media.id).toList(growable: false);
                  Navigator.of(context).pushNamed(AppRoutes.mediaDetails, arguments: MediaDetailsArgs(
                    mediaId: m.id, 
                    mediaIds: mediaIds,
                    showWatermark: (widget.folderId == null ? null : ref.read(folderProvider).folderById(widget.folderId!))?.showWatermark ?? false,
                    watermarkUrl: ref.read(authStateProvider).user?.avatarUrl,
                  ));
                }
              },
              onLongPress: () => _toggleSelection(m.id),
            );
        }
      },
    );
  }

  Widget _buildDetailsView({
    required AppLocalizations l10n,
    required List<ExplorerItem> items,
  }) {
    final rows = items.map((item) {
      switch (item) {
        case FolderItem():
          final f = item.folder;
          return _DetailsRow(
            name: f.name,
            type: l10n.folderExplorerFolders,
            itemCount: f.albumCount + f.photoCount + f.videoCount,
            size: f.photoCount + f.videoCount,
            date: f.createdAt,
            onTap: () => _openFolder(f.id),
          );
        case AlbumItem():
          final a = item.album;
          return _DetailsRow(
            name: a.name,
            type: l10n.albums,
            itemCount: a.photoCount + a.videoCount,
            size: a.photoCount + a.videoCount,
            date: a.updatedAt,
            onTap: () => _openAlbum(a.id),
          );
        case MediaItem():
          final m = item.media;
          return _DetailsRow(
            name: m.fileName,
            type: l10n.folderExplorerLooseMedia,
            itemCount: 1,
            size: m.size,
            date: m.createdAt,
            onTap: () {
              final mediaIds = items.whereType<MediaItem>().map((i) => i.media.id).toList(growable: false);
              Navigator.of(context).pushNamed(AppRoutes.mediaDetails, arguments: MediaDetailsArgs(
                mediaId: m.id, 
                mediaIds: mediaIds,
                showWatermark: (widget.folderId == null ? null : ref.read(folderProvider).folderById(widget.folderId!))?.showWatermark ?? false,
                watermarkUrl: ref.read(authStateProvider).user?.avatarUrl,
              ));
            },
          );
      }
    }).toList(growable: false);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: DataTable(
        columns: [
          DataColumn(label: Text(l10n.folderExplorerSortByName)),
          DataColumn(label: Text(l10n.folderExplorerType)),
          DataColumn(label: Text(l10n.folderExplorerItems)),
          DataColumn(label: Text(l10n.folderExplorerSortBySize)),
          DataColumn(label: Text(l10n.folderExplorerSortByDate)),
        ],
        rows: rows
            .map(
              (row) => DataRow(
                cells: [
                  DataCell(Text(row.name), onTap: row.onTap),
                  DataCell(Text(row.type), onTap: row.onTap),
                  DataCell(Text('${row.itemCount}'), onTap: row.onTap),
                  DataCell(Text('${row.size}'), onTap: row.onTap),
                  DataCell(Text(_dateFormat.format(row.date)), onTap: row.onTap),
                ],
              ),
            )
            .toList(growable: false),
      ),
    );
  }
  List<ExplorerItem> _combineAndSortItems(
    List<FolderModel> folders,
    List<AlbumModel> albums,
    List<MediaModel> media,
    FolderExplorerPrefs prefs,
  ) {
    final items = <ExplorerItem>[
      ...folders.map((f) => FolderItem(f)),
      ...albums.map((a) => AlbumItem(a)),
      ...media.map((m) => MediaItem(m)),
    ];

    items.sort((a, b) {
      if (prefs.foldersFirst) {
        final cmpType = a.typeOrder.compareTo(b.typeOrder);
        if (cmpType != 0) return cmpType;
      }

      int cmp = 0;
      switch (prefs.sortField) {
        case ExplorerSortField.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case ExplorerSortField.date:
          cmp = a.date.compareTo(b.date);
          break;
        case ExplorerSortField.dateCreated:
          cmp = a.dateCreated.compareTo(b.dateCreated);
          break;
        case ExplorerSortField.size:
          cmp = a.sortSize.compareTo(b.sortSize);
          break;
      }
      return prefs.ascending ? cmp : -cmp;
    });

    return items;
  }


  void _openFolder(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FolderExplorerScreen(folderId: id)),
    );
  }

  void _openAlbum(String id) {
    Navigator.of(context).pushNamed(AppRoutes.adminAlbumDetails, arguments: id);
  }

  Future<void> _handleFolderAction(FolderModel folder, _FolderAction action) async {
    switch (action) {
      case _FolderAction.rename:
        Navigator.of(context).pushNamed(AppRoutes.adminFolderRename, arguments: folder);
        break;
      case _FolderAction.move:
        Navigator.of(context).pushNamed(AppRoutes.adminFolderMove, arguments: folder);
        break;
      case _FolderAction.hide:
        try {
          await ref.read(folderRepositoryProvider).updateFolder(folder.copyWith(isHidden: !folder.isHidden));
          ref.invalidate(folderContentsProvider);
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
        break;
      case _FolderAction.share:
        Navigator.of(context).pushNamed(
          AppRoutes.shareLinksList,
          arguments: {
            'folderId': folder.id,
            'title': folder.name,
          },
        );
        break;
      case _FolderAction.download:
        try {
          await ref.read(zipJobRepositoryProvider).createJob(kind: 'zip_folder', targetId: folder.id);
          if (mounted) Navigator.of(context).pushNamed(AppRoutes.zipJobs);
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error starting download: $e')));
        }
        break;
      case _FolderAction.delete:
        final mode = await showSafeDeleteDialog(
          context: context,
          itemName: folder.name,
          getPreview: (mode) => ref.read(folderRepositoryProvider).previewDeleteFolder(folder.id, mode: mode),
          isHidden: folder.isHidden,
        );
        if (mode != null && mounted) {
          try {
            await ref.read(folderProvider).deleteFolder(folder.id, mode: mode);
            ref.invalidate(folderContentsProvider);
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
          }
        }
        break;
      case _FolderAction.faceSearch:
        ref.read(faceSearchProvider.notifier).useMyLibrary(
          folderId: folder.id,
          scopeLabel: folder.name,
        );
        Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
        break;
      case _FolderAction.watermark:
        try {
          await ref.read(folderRepositoryProvider).updateFolder(folder.copyWith(showWatermark: !(folder.showWatermark ?? false)));
          ref.invalidate(folderContentsProvider);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Watermark ${!(folder.showWatermark ?? false) ? "enabled" : "disabled"} for folder')));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
        break;
    }
  }

  Future<void> _handleAlbumAction(AlbumModel album, _AlbumAction action) async {
    switch (action) {
      case _AlbumAction.rename:
        Navigator.of(context).pushNamed(AppRoutes.adminAlbumEdit, arguments: album.id);
        break;
      case _AlbumAction.move:
        // Was a silent no-op (the handler was commented out). Reuse the
        // bulk-move dialog with just this album selected.
        setState(() {
          _selectedIds
            ..clear()
            ..add(album.id);
        });
        await _handleBulkMove([AlbumItem(album)]);
        if (mounted) _clearSelection();
        break;
      case _AlbumAction.share:
        Navigator.of(context).pushNamed(AppRoutes.albumShareSettings, arguments: {
          'albumId': album.id,
          'albumName': album.name,
        });
        break;
      case _AlbumAction.download:
        try {
          await ref.read(zipJobRepositoryProvider).createJob(kind: 'zip_album', targetId: album.id);
          if (mounted) Navigator.of(context).pushNamed(AppRoutes.zipJobs);
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error starting download: $e')));
        }
        break;
      case _AlbumAction.faceSearch:
        ref.read(faceSearchProvider.notifier).useMyLibrary(
          albumId: album.id,
          scopeLabel: album.name,
        );
        Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
        break;
      case _AlbumAction.delete:
        final mode = await showSafeDeleteDialog(
          context: context,
          itemName: album.name,
          getPreview: (mode) => ref.read(albumRepositoryProvider).previewDeleteAlbum(album.id, mode: mode),
        );
        if (mode != null && mounted) {
          try {
            await ref.read(albumRepositoryProvider).deleteAlbum(album.id, mode: mode);
            ref.invalidate(albumAsyncProvider);
            ref.invalidate(folderContentsProvider);
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
          }
        }
        break;
    }
  }

  Future<void> _handleMediaAction(MediaModel media, _MediaAction action) async {
    switch (action) {
      case _MediaAction.open:
        final folderContents = ref.read(folderContentsProvider(widget.folderId ?? 'root')).value;
        final mediaIds = folderContents?.media.map((m) => m.id).toList();
        Navigator.of(context).pushNamed(AppRoutes.mediaDetails, arguments: MediaDetailsArgs(mediaId: media.id, mediaIds: mediaIds));
        break;
      case _MediaAction.move:
        await MediaBatchWorkflows.openMove(context: context, mediaIds: [media.id]);
        if (mounted) ref.invalidate(folderContentsProvider);
        break;
      case _MediaAction.delete:
        final confirm = await showDeleteConfirmationDialog(
          context: context,
          title: 'Move to Trash?',
          message: 'The selected item will be moved to Trash.',
        );
        if (confirm == true && mounted) {
          try {
            await ref.read(mediaRepositoryProvider).deleteMedia(media.id);
            ref.invalidate(folderContentsProvider);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Item moved to Trash')));
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
          }
        }
        break;
    }
  }

  Future<void> _handleBulkDelete(List<ExplorerItem> allItems) async {
    final itemsToDelete = allItems.where((i) => _selectedIds.contains(i.id)).toList();
    if (itemsToDelete.isEmpty) return;

    final confirm = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete ${itemsToDelete.length} items?',
      message: 'Selected items will be moved to Trash.',
      confirmText: 'Move to Trash',
    );
    if (!mounted || confirm != true) return;

    final folderController = ref.read(folderProvider);
    final albumController = ref.read(albumProvider);
    final mediaRepo = ref.read(mediaRepositoryProvider);

    SnackBarHelper.showSuccess(context, 'Moving items to Trash...');

    for (final item in itemsToDelete) {
      if (item is FolderItem) {
        await folderController.deleteFolder(item.id, mode: DeleteMode.moveUp);
      } else if (item is AlbumItem) {
        await albumController.deleteAlbum(item.id, mode: DeleteMode.moveUp);
      } else if (item is MediaItem) {
        await mediaRepo.deleteMedia(item.id);
      }
    }

    _clearSelection();
    ref.invalidate(folderContentsProvider);
  }

  Future<void> _handleBulkMove(List<ExplorerItem> allItems) async {
    final itemsToMove = allItems.where((i) => _selectedIds.contains(i.id)).toList();
    if (itemsToMove.isEmpty) return;

    final folderController = ref.read(folderProvider);
    final allFolders = folderController.folders;

    // candidate parents: can't move into any selected folder, or their descendants.
    final invalidFolderIds = <String>{};
    for (final item in itemsToMove) {
      if (item is FolderItem) {
        invalidFolderIds.add(item.id);
        invalidFolderIds.addAll(folderController.descendantsOf(item.id).map((f) => f.id));
      }
    }

    final candidateParents = allFolders.where((f) => !invalidFolderIds.contains(f.id)).toList();

    String? selectedParentId = widget.folderId; // Default to current or root, wait we should default to something else if we are moving, probably root

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            title: Text('Move ${itemsToMove.length} items', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
            content: DropdownButtonFormField<String?>(
              initialValue: null, // Always start at root in dialog
              dropdownColor: context.surfaceColor,
              decoration: InputDecoration(
                labelText: 'Destination folder',
                labelStyle: TextStyle(color: context.textPrimary),
              ),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text('Root level', style: TextStyle(color: context.textPrimary))),
                ...candidateParents.map((f) => DropdownMenuItem<String?>(
                  value: f.id,
                  child: Text(f.name, style: TextStyle(color: context.textPrimary)),
                )),
              ],
              onChanged: (v) => setState(() => selectedParentId = v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Cancel', style: TextStyle(color: context.textMuted)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Move'),
              ),
            ],
          );
        },
      ),
    );

    if (!mounted || confirm != true) return;

    SnackBarHelper.showSuccess(context, 'Moving items...');

    final mediaRepo = ref.read(mediaRepositoryProvider);
    final albumController = ref.read(albumProvider);

    for (final item in itemsToMove) {
      if (item is FolderItem) {
        await folderController.moveFolder(item.id, selectedParentId);
      } else if (item is AlbumItem) {
        await albumController.moveToFolder(item.id, selectedParentId);
      } else if (item is MediaItem) {
        await mediaRepo.moveMedia(id: item.id, folderId: selectedParentId, albumId: null);
      }
    }

    _clearSelection();
    ref.invalidate(folderContentsProvider);
  }
}

enum _ExplorerMenuAction { allAlbums }

enum _FolderAction { rename, move, hide, share, download, delete, faceSearch, watermark }

enum _AlbumAction { rename, move, share, download, faceSearch, delete }

enum _MediaAction { open, move, delete }

class _DetailsRow {
  const _DetailsRow({
    required this.name,
    required this.type,
    required this.itemCount,
    required this.size,
    required this.date,
    this.onTap,
  });

  final String name;
  final String type;
  final int itemCount;
  final int size;
  final DateTime date;
  final VoidCallback? onTap;
}

sealed class ExplorerItem {
  String get id;
  String get name;
  DateTime get date;
  DateTime get dateCreated;
  int get sortSize;
  int get typeOrder;
}

class FolderItem extends ExplorerItem {
  final FolderModel folder;
  FolderItem(this.folder);
  @override String get id => folder.id;
  @override String get name => folder.name;
  @override DateTime get date => folder.createdAt;
  @override DateTime get dateCreated => folder.createdAt;
  @override int get sortSize => folder.photoCount + folder.videoCount + folder.albumCount;
  @override int get typeOrder => 0;
}

class AlbumItem extends ExplorerItem {
  final AlbumModel album;
  AlbumItem(this.album);
  @override String get id => album.id;
  @override String get name => album.name;
  @override DateTime get date => album.updatedAt;
  @override DateTime get dateCreated => album.createdAt;
  @override int get sortSize => album.photoCount + album.videoCount;
  @override int get typeOrder => 1;
}

class MediaItem extends ExplorerItem {
  final MediaModel media;
  MediaItem(this.media);
  @override String get id => media.id;
  @override String get name => media.fileName;
  @override DateTime get date => media.createdAt;
  @override DateTime get dateCreated => media.createdAt;
  @override int get sortSize => media.size;
  @override int get typeOrder => 2;
}

class _FolderGridTile extends StatelessWidget {
  const _FolderGridTile({
    required this.folder,
    required this.onTap,
    required this.onAction,
    this.onLongPress,
    this.isSelected = false,
  });

  final FolderModel folder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(_FolderAction) onAction;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: context.surfaceColor.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: context.borderColor),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showText = constraints.maxHeight > 60;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (folder.previewThumbnails.isNotEmpty)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: showText ? AppSpacing.sm : 0),
                          child: GridView.count(
                            crossAxisCount: 2,
                            mainAxisSpacing: 2,
                            crossAxisSpacing: 2,
                            physics: const NeverScrollableScrollPhysics(),
                            children: folder.previewThumbnails.take(4).map((url) {
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(
                                  url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (c, e, s) => const Icon(Icons.broken_image),
                                ),
                              );
                            }).toList(growable: false),
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: folder.gradientArgb.isNotEmpty
                                  ? folder.gradientArgb.map((a) => Color(a)).toList(growable: false)
                                  : [AppColors.primary, AppColors.primary.withValues(alpha: 0.5)],
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Center(child: Icon(Icons.folder_rounded, color: Colors.white, size: showText ? 32 : 18)),
                        ),
                      ),
                    if (showText) ...[
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: context.textPrimary),
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${folder.albumCount + folder.photoCount + folder.videoCount} ${AppLocalizations.of(context)!.folderExplorerItems}',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textMuted),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        if (folder.hasShareLink || folder.isHidden)
          Positioned(
            top: 4,
            left: 4,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (folder.hasShareLink)
                  Container(
                    padding: const EdgeInsets.all(4),
                    margin: const EdgeInsets.only(right: 4),
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.link_rounded, size: 14, color: Colors.white),
                  ),
                if (folder.isHidden)
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.visibility_off_rounded, size: 14, color: Colors.white),
                  ),
              ],
            ),
          ),
        Positioned(
          top: 0,
          right: 0,
          child: PopupMenuButton<_FolderAction>(
            onSelected: onAction,
            itemBuilder: (context) => [
              const PopupMenuItem(value: _FolderAction.rename, child: Text('Rename')),
              const PopupMenuItem(value: _FolderAction.move, child: Text('Move')),
              const PopupMenuItem(value: _FolderAction.hide, child: Text('Hide')),
              const PopupMenuItem(value: _FolderAction.share, child: Text('Share')),
              const PopupMenuItem(value: _FolderAction.download, child: Text('Download')),
              PopupMenuItem(
                value: _FolderAction.watermark, 
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Watermark'),
                    if (folder.showWatermark == true) const Icon(Icons.check, size: 16, color: AppColors.primary),
                  ],
                ),
              ),
              const PopupMenuItem(value: _FolderAction.faceSearch, child: Text('Face Search')),
              const PopupMenuItem(value: _FolderAction.delete, child: Text('Delete')),
            ],
          ),
        ),
      ],
    );
  }
}

class _AlbumGridTile extends StatelessWidget {
  const _AlbumGridTile({
    required this.album,
    required this.onTap,
    required this.onAction,
    this.onLongPress,
    this.isSelected = false,
  });

  final AlbumModel album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(_AlbumAction) onAction;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.lg - 1)),
                    child: album.coverThumbnailUrl != null
                        ? Image.network(
                            album.coverThumbnailUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) => const Icon(Icons.broken_image),
                          )
                        : Container(
                            decoration: BoxDecoration(gradient: LinearGradient(colors: album.gradient)),
                            child: const Center(child: Icon(Icons.photo_album, color: Colors.white, size: 32)),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: context.textPrimary),
                      ),
                      Text(
                        '${album.photoCount + album.videoCount}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: PopupMenuButton<_AlbumAction>(
            onSelected: onAction,
            itemBuilder: (context) => [
              const PopupMenuItem(value: _AlbumAction.rename, child: Text('Rename')),
              const PopupMenuItem(value: _AlbumAction.move, child: Text('Move')),
              const PopupMenuItem(value: _AlbumAction.share, child: Text('Share')),
              const PopupMenuItem(value: _AlbumAction.download, child: Text('Download')),
              const PopupMenuItem(value: _AlbumAction.faceSearch, child: Text('Face Search')),
              const PopupMenuItem(value: _AlbumAction.delete, child: Text('Delete')),
            ],
          ),
        ),
      ],
    );
  }
}

class _MediaGridTile extends StatelessWidget {
  const _MediaGridTile({
    required this.media,
    required this.onAction,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
    this.showWatermark = false,
    this.watermarkUrl,
  });

  final MediaModel media;
  final void Function(_MediaAction) onAction;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final bool showWatermark;
  final String? watermarkUrl;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: media.remoteThumbnailUrl != null
                ? Image.network(
                    media.remoteThumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (c, e, s) => const Icon(Icons.broken_image),
                  )
                : Container(
                    color: context.borderColor,
                    child: const Icon(Icons.image),
                  ),
          ),
          if (isSelected)
            Container(
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.primary, width: 3),
              ),
              child: const Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.all(4.0),
                  child: Icon(Icons.check_circle, color: AppColors.primary),
                ),
              ),
            ),
          if (media.type == MediaType.video)
            Positioned(
              bottom: 4,
              left: 4,
              right: 4,
              child: Row(
                children: [
                  const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  if (media.duration != null)
                    Text(
                      "${media.duration!.inMinutes}:${media.duration!.inSeconds.remainder(60).toString().padLeft(2, '0')}",
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: PopupMenuButton<_MediaAction>(
              onSelected: onAction,
              itemBuilder: (context) => [
                const PopupMenuItem(value: _MediaAction.open, child: Text('Open')),
                const PopupMenuItem(value: _MediaAction.move, child: Text('Move')),
                const PopupMenuItem(value: _MediaAction.delete, child: Text('Delete')),
              ],
            ),
          ),
          if (showWatermark && watermarkUrl != null)
            WatermarkOverlay(url: watermarkUrl!),
        ],
      ),
    );
  }
}
