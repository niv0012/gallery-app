import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/collection_display_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/gallery_collections_provider.dart';
import '../../providers/media_provider.dart';
import '../../providers/auth_providers.dart' show apiClientProvider;
import '../../services/media_file_cache.dart';
import '../../services/download_service_impl.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:share_plus/share_plus.dart';

import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/delete_confirmation_dialog.dart';
import '../../widgets/common/snackbar_helper.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../core/theme/theme_context.dart';

/// Collections module.
///
/// Everything on this screen is driven by [galleryCollectionsProvider] and
/// [albumProvider] — a collection is an ordered group of *albums* (each
/// album's own photos/videos live in the album itself), matching the
/// backend (`app/api/routes/collections.py`). There is no sample/demo
/// content: an account with zero collections renders the empty state, a
/// collection with zero albums renders a 0-album count and a generated
/// placeholder cover instead of a picture, and every count/date/thumbnail
/// updates the moment the underlying provider changes. See
/// [CollectionDisplayModel] for the handful of fields (favorite/shared)
/// that are honestly derived because this app doesn't have a dedicated
/// data source for them yet.
///
/// Chrome-wise this screen now uses the same [CustomAppBar] every other
/// pushed screen (Albums, Folders, Media) uses instead of its own large,
/// bespoke gradient hero header — so it reads as part of the app instead
/// of a one-off page.
class CollectionsScreen extends ConsumerStatefulWidget {
  const CollectionsScreen({super.key});

  @override
  ConsumerState<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends ConsumerState<CollectionsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _selectedFilter = 'All';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> _availableFilters(List<CollectionDisplayModel> items) {
    final filters = <String>['All'];
    if (items.any((c) => c.isFavorite)) filters.add('Favorites');
    if (items.any((c) => c.isShared)) filters.add('Shared');
    if (items.isNotEmpty) filters.add('Recent');
    return filters;
  }

  List<CollectionDisplayModel> _applyFilter(
    List<CollectionDisplayModel> items,
    String filter,
  ) {
    switch (filter) {
      case 'Favorites':
        return items.where((c) => c.isFavorite).toList();
      case 'Shared':
        return items.where((c) => c.isShared).toList();
      case 'Recent':
        final now = DateTime.now();
        final recent = items
            .where((c) => now.difference(c.updatedAt).inDays <= 7)
            .toList();
        if (recent.isNotEmpty) return recent;
        return items.take(5).toList();
      default:
        return items;
    }
  }

  Future<void> _openCreateDialog(BuildContext context) async {
    final ctrl = ref.read(galleryCollectionsProvider);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _TextInputDialog(
        title: 'Create Collection',
        hint: 'Collection name',
        confirmLabel: 'Create',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ctrl.createCollection(name: name);
  }

  Future<void> _openRenameDialog(
    BuildContext context,
    CollectionDisplayModel model,
  ) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextInputDialog(
        title: 'Rename Collection',
        hint: 'Collection name',
        confirmLabel: 'Save',
        initialValue: model.title,
      ),
    );
    if (newName == null || newName.trim().isEmpty || !context.mounted) return;
    await ref.read(galleryCollectionsProvider).renameCollection(
          collectionId: model.id,
          newName: newName,
        );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    CollectionDisplayModel model,
  ) async {
    final confirmed = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete item?',
      message:
          'This will permanently remove "${model.title}". The galleries inside it are not deleted. This cannot be undone.',
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(galleryCollectionsProvider).deleteCollection(model.id);
    if (!context.mounted) return;
    SnackBarHelper.showSuccess(context, '"${model.title}" deleted');
  }

  Future<void> _handleDownloadCollection(String collectionId, List<CollectionDisplayModel> allDisplay) async {
    final c = allDisplay.firstWhere((x) => x.id == collectionId, orElse: () => allDisplay.first);
    if (c.id != collectionId) return;

    final collectionsCtrl = ref.read(galleryCollectionsProvider);
    final rawCollection = collectionsCtrl.collections.firstWhere((x) => x.id == collectionId);

    final allMedia = ref.read(mediaProvider).allMedia;
    
    // Find all media in any album of this collection
    final mediaToDownload = allMedia.where((m) => rawCollection.galleryIds.contains(m.albumId)).toList();

    if (mediaToDownload.isEmpty) {
      AppToast.show(context, 'This collection is empty.');
      return;
    }

    if (kIsWeb) {
      AppToast.show(context, 'Bulk downloading is not currently supported on web.');
      return;
    }

    AppToast.show(context, 'Downloading ${mediaToDownload.length} items in background...');

    final apiClient = ref.read(apiClientProvider);
    final cache = const MediaFileCache();
    
    final filePaths = <String>[];
    final mediaIds = <String>[];

    for (final m in mediaToDownload) {
      final path = await cache.localPathFor(m);
      if (path != null) {
        filePaths.add(path);
        mediaIds.add(m.id);
      }
    }

    if (filePaths.isEmpty || !context.mounted) return;

    final downloadService = const DownloadServiceImpl();
    await downloadService.downloadBulkOriginals(
      context: context,
      filePaths: filePaths,
      mediaIds: mediaIds,
      apiClient: apiClient,
    );
  }

  /// Returns a chosen collection id: straight through when
  /// there's exactly one, via a picker sheet when there's more than one,
  /// or null if there are none (after attempting creation) or the user cancels.
  Future<String?> _pickCollection(
    BuildContext context,
    List<CollectionDisplayModel> items,
    String title,
  ) async {
    if (items.isEmpty) {
      await _openCreateDialog(context);
      return null;
    }
    if (items.length == 1) {
      return items.first.id;
    }

    return await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CollectionPickerSheet(items: items, title: title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final collectionsCtrl = ref.watch(galleryCollectionsProvider);
    final albumCtrl = ref.watch(albumProvider);

    final allDisplay = buildCollectionDisplayModels(
      collections: collectionsCtrl.collections,
      allAlbums: albumCtrl.allAlbums,
    );

    final availableFilters = _availableFilters(allDisplay);
    if (!availableFilters.contains(_selectedFilter)) {
      _selectedFilter = 'All';
    }

    final searched = _query.trim().isEmpty
        ? allDisplay
        : allDisplay
            .where((c) =>
                c.title.toLowerCase().contains(_query.trim().toLowerCase()))
            .toList();
    final filtered = _applyFilter(searched, _selectedFilter);

    final isInitialLoading = collectionsCtrl.isLoading &&
        collectionsCtrl.collections.isEmpty &&
        collectionsCtrl.lastError == null;
    final hasError = collectionsCtrl.lastError != null &&
        collectionsCtrl.collections.isEmpty;

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Collections',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Create Collection',
            icon: Icon(Icons.add_rounded),
            onPressed: () => _openCreateDialog(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: () => collectionsCtrl.load(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: _SearchAndFilters(
                  searchController: _searchController,
                  onSearchChanged: (v) => setState(() => _query = v),
                  filters: availableFilters,
                  selectedFilter: _selectedFilter,
                  onFilterSelected: (f) => setState(() => _selectedFilter = f),
                ),
              ),
              SliverToBoxAdapter(
                child: AnimatedSwitcher(
                  duration: AppDurations.fast,
                  child: isInitialLoading
                      ? const _LoadingSection()
                      : hasError
                          ? _ErrorSection(
                              onRetry: () => collectionsCtrl.load(),
                            )
                          : allDisplay.isEmpty
                              ? _EmptySection(
                                  onCreate: () => _openCreateDialog(context),
                                )
                              : _CollectionsContent(
                                  key: const ValueKey('content'),
                                  filtered: filtered,
                                  query: _query,
                                  selectedFilter: _selectedFilter,
                                  onCreateTap: () => _openCreateDialog(context),
                                  onAddPhotos: () async {
                                    final chosen = await _pickCollection(
                                        context, allDisplay, 'Add albums to collection');
                                    if (chosen == null || !context.mounted) return;
                                    Navigator.of(context).pushNamed(
                                      AppRoutes.collectionsDetails,
                                      arguments: chosen,
                                    );
                                  },
                                  onShare: () async {
                                    final chosen = await _pickCollection(
                                        context, allDisplay, 'Share collection');
                                    if (chosen == null || !context.mounted) return;
                                    final c = allDisplay.firstWhere((x) => x.id == chosen);
                                    Share.share(
                                      'Check out my photo collection: ${c.title}\nhttps://api.picgallery.in/gallery/$chosen'
                                    );
                                  },
                                  onDownload: () async {
                                    final chosen = await _pickCollection(
                                        context, allDisplay, 'Download collection');
                                    if (chosen == null || !context.mounted) return;
                                    await _handleDownloadCollection(chosen, allDisplay);
                                  },
                                  onRename: (m) =>
                                      _openRenameDialog(context, m),
                                  onDelete: (m) => _confirmDelete(context, m),
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

// ---------------------------------------------------------------------
// Search + filter row — sits directly under the CustomAppBar, same slim
// footprint used by Media/Albums search fields instead of an oversized
// hero search bar.
// ---------------------------------------------------------------------

class _SearchAndFilters extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final List<String> filters;
  final String selectedFilter;
  final ValueChanged<String> onFilterSelected;

  const _SearchAndFilters({
    required this.searchController,
    required this.onSearchChanged,
    required this.filters,
    required this.selectedFilter,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search collections',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close_rounded),
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
        ),
        SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: filters.length,
            separatorBuilder: (_, __) => SizedBox(width: 8),
            itemBuilder: (context, index) {
              final label = filters[index];
              final isSelected = label == selectedFilter;
              return InkWell(
                onTap: () => onFilterSelected(label),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border:
                        isSelected ? null : Border.all(color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkBorder : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : (Theme.of(context).brightness == Brightness.dark
                              ? AppColors.textOnDark
                              : AppColors.text),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Loaded-state content — featured carousel, action grid and the recent
// list. Pulled out of build() so it can be a const-friendly, individually
// diffable subtree for AnimatedSwitcher and so it can apply a centered
// max-width on tablets/landscape without touching the rest of the
// screen's logic.
// ---------------------------------------------------------------------

class _CollectionsContent extends StatelessWidget {
  final List<CollectionDisplayModel> filtered;
  final String query;
  final String selectedFilter;
  final VoidCallback onCreateTap;
  final VoidCallback onAddPhotos;
  final VoidCallback onShare;
  final VoidCallback onDownload;
  final ValueChanged<CollectionDisplayModel> onRename;
  final ValueChanged<CollectionDisplayModel> onDelete;

  const _CollectionsContent({
    super.key,
    required this.filtered,
    required this.query,
    required this.selectedFilter,
    required this.onCreateTap,
    required this.onAddPhotos,
    required this.onShare,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxContentWidth =
            constraints.maxWidth > 720 ? 720.0 : constraints.maxWidth;
        return Center(
          child: SizedBox(
            width: maxContentWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: AppSpacing.lg),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Text(
                    'Featured collections',
                    style: TextStyle(
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text),
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                if (filtered.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: EmptyStateCard(
                      icon: Icons.search_off_rounded,
                      message: query.trim().isNotEmpty
                          ? 'No collections match "${query.trim()}".'
                          : 'No collections in "$selectedFilter" yet.',
                    ),
                  )
                else
                  _FeaturedCarousel(items: filtered.take(8).toList()),
                SizedBox(height: AppSpacing.xl),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: _ActionGrid(
                    onCreate: onCreateTap,
                    onAddPhotos: onAddPhotos,
                    onShare: onShare,
                    onDownload: onDownload,
                  ),
                ),
                SizedBox(height: AppSpacing.xl),
                if (filtered.isNotEmpty) ...[
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Text(
                      'All collections',
                      style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Column(
                      children: [
                        for (final c in filtered)
                          Padding(
                            padding: EdgeInsets.only(bottom: AppSpacing.sm),
                            child: _RecentCollectionTile(
                              model: c,
                              onRename: () => onRename(c),
                              onDelete: () => onDelete(c),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: AppSpacing.xxl),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Featured carousel
// ---------------------------------------------------------------------

class _FeaturedCarousel extends StatelessWidget {
  final List<CollectionDisplayModel> items;

  const _FeaturedCarousel({required this.items});

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Updated just now';
    if (diff.inMinutes < 60) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Updated ${diff.inHours}h ago';
    if (diff.inDays < 7) return 'Updated ${diff.inDays}d ago';
    return 'Updated ${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 218,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(width: AppSpacing.md),
        itemBuilder: (context, index) {
          final c = items[index];
          return _FeaturedCard(model: c, timeAgoText: _timeAgo(c.updatedAt));
        },
      ),
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  final CollectionDisplayModel model;
  final String timeAgoText;

  const _FeaturedCard({required this.model, required this.timeAgoText});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pushNamed(
            AppRoutes.collectionsDetails,
            arguments: model.id,
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: AppShadows.soft(AppColors.primary, opacity: 0.16),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CollectionCoverImage(model: model),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.65),
                      ],
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
                if (model.isShared)
                  const Positioned(
                    left: 12,
                    top: 12,
                    child: _Badge(
                      icon: Icons.people_alt_rounded,
                      label: 'Shared',
                    ),
                  ),
                if (model.isFavorite)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.favorite_rounded,
                          color: AppColors.accent, size: 16),
                    ),
                  ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        model.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${model.albumCount} album${model.albumCount == 1 ? '' : 's'} · $timeAgoText',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (model.previewAlbums.length > 1) ...[
                        SizedBox(height: 8),
                        _PreviewAvatarStack(items: model.previewAlbums),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Badge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 12),
          SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewAvatarStack extends StatelessWidget {
  final List<AlbumModel> items;

  const _PreviewAvatarStack({required this.items});

  @override
  Widget build(BuildContext context) {
    final shown = items.take(4).toList();
    return SizedBox(
      height: 22,
      width: 22 + (shown.length - 1) * 14.0,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 14.0,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.4),
                ),
                clipBehavior: Clip.antiAlias,
                child: _AlbumSwatch(album: shown[i]),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small gradient swatch representing one linked album — albums have no
/// real cover photo of their own (see [AlbumCoverPlaceholder]), only a
/// stored gradient tint, so this is the honest equivalent of the old
/// per-media thumbnail.
class _AlbumSwatch extends StatelessWidget {
  final AlbumModel album;

  const _AlbumSwatch({required this.album});

  @override
  Widget build(BuildContext context) {
    final colors = album.gradient.length >= 2
        ? [album.gradient[0], album.gradient[1]]
        : const [AppColors.primary, AppColors.secondary];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
      ),
    );
  }
}

/// Full-size cover for a featured/recent collection card. Prefers the
/// collection's most recently linked album's gradient; falls back to a
/// deterministic gradient + icon when the collection has no albums yet.
class _CollectionCoverImage extends StatelessWidget {
  final CollectionDisplayModel model;

  const _CollectionCoverImage({required this.model});

  @override
  Widget build(BuildContext context) {
    final cover = model.coverAlbum;
    if (cover == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: model.fallbackGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Icon(
            Icons.collections_bookmark_rounded,
            color: Colors.white.withValues(alpha: 0.85),
            size: 36,
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: cover.gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(Icons.photo_library_rounded, size: 34, color: Colors.white),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Action grid
// ---------------------------------------------------------------------

class _ActionGrid extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onAddPhotos;
  final VoidCallback onShare;
  final VoidCallback onDownload;

  const _ActionGrid({
    required this.onCreate,
    required this.onAddPhotos,
    required this.onShare,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final actions = [
      (
        icon: Icons.create_new_folder_rounded,
        label: 'Create Collection',
        bg: AppColors.primary.withValues(alpha: 0.12),
        fg: AppColors.primary,
        onTap: onCreate,
      ),
      (
        icon: Icons.add_photo_alternate_rounded,
        label: 'Add Albums',
        bg: AppColors.accent.withValues(alpha: 0.12),
        fg: AppColors.accent,
        onTap: onAddPhotos,
      ),
      (
        icon: Icons.ios_share_rounded,
        label: 'Share Collection',
        bg: AppColors.secondary.withValues(alpha: 0.12),
        fg: AppColors.secondary,
        onTap: onShare,
      ),
      (
        icon: Icons.download_rounded,
        label: 'Download Collection',
        bg: AppColors.success.withValues(alpha: 0.14),
        fg: Color(0xFF17843F),
        onTap: onDownload,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            childAspectRatio: 2.5,
          ),
          itemCount: actions.length,
          itemBuilder: (context, index) {
            final a = actions[index];
            return Material(
              color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: a.onTap,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkBorder : AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: a.bg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(a.icon, color: a.fg, size: 19),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          a.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.textOnDark
                                    : AppColors.text),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }
}

// ---------------------------------------------------------------------
// Collection list tile — thumbnail, title, subtitle/count, last updated
// and a trailing overflow menu (open is the default tap; rename/delete
// live behind the menu), mirroring the Media grid's row-tile treatment:
// flat white surface, hairline border, no oversized card.
// ---------------------------------------------------------------------

class _RecentCollectionTile extends StatelessWidget {
  final CollectionDisplayModel model;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _RecentCollectionTile({
    required this.model,
    required this.onRename,
    required this.onDelete,
  });

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => Navigator.of(context).pushNamed(
          AppRoutes.collectionsDetails,
          arguments: model.id,
        ),
        child: Container(
          padding: EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkBorder : AppColors.border),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 54,
                  height: 54,
                  child: _CollectionCoverImage(model: model),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '${model.albumCount} album${model.albumCount == 1 ? '' : 's'} · Updated ${_timeAgo(model.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.subtitleOnDark
                            : AppColors.subtitle),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: Icon(Icons.more_vert_rounded,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
                onSelected: (value) {
                  if (value == 'rename') onRename();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Rename'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 18, color: AppColors.error),
                        SizedBox(width: 10),
                        Text('Delete',
                            style: TextStyle(color: AppColors.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Collection picker sheet (used by Share / Add photos / Download actions
// when there's more than one collection to choose from)
// ---------------------------------------------------------------------

class _CollectionPickerSheet extends StatelessWidget {
  final List<CollectionDisplayModel> items;
  final String title;

  const _CollectionPickerSheet({
    required this.items,
    this.title = 'Choose a collection',
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: EdgeInsets.all(AppSpacing.md),
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: AppSpacing.sm),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: context.borderColor,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.only(bottom: AppSpacing.md),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final c = items[index];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: _CollectionCoverImage(model: c),
                      ),
                    ),
                    title: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                      ),
                    ),
                    subtitle: Text(
                      '${c.albumCount} album${c.albumCount == 1 ? '' : 's'}',
                    ),
                    onTap: () => Navigator.of(context).pop(c.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------

class _EmptySection extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptySection({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.xl),
      child: Container(
        padding: EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: AppColors.softWash,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.collections_bookmark_rounded,
                  size: 42, color: AppColors.primary),
            ),
            SizedBox(height: AppSpacing.lg),
            Text(
              'No collections yet',
              style: TextStyle(
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.textOnDark
                    : AppColors.text),
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Create collections to group albums together across galleries.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle),
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: AppSpacing.lg),
            GradientButton(
              label: 'Create Collection',
              icon: Icons.add_rounded,
              height: 50,
              onPressed: onCreate,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Error state
// ---------------------------------------------------------------------

class _ErrorSection extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorSection({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.xl),
      child: Container(
        padding: EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline_rounded,
                  size: 34, color: AppColors.error),
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'Unable to load collections',
              style: TextStyle(
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.textOnDark
                    : AppColors.text),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: AppSpacing.lg),
            GradientButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              outlined: true,
              height: 46,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Loading skeletons — sized to match the real layout so content doesn't
// jump once it arrives.
// ---------------------------------------------------------------------

class _LoadingSection extends StatelessWidget {
  const _LoadingSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 218,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: 3,
              separatorBuilder: (_, __) => SizedBox(width: AppSpacing.md),
              itemBuilder: (_, __) => const _Shimmer(
                child:
                    _SkeletonBox(width: 250, height: 218, radius: AppRadius.lg),
              ),
            ),
          ),
          SizedBox(height: AppSpacing.xl),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              children: List.generate(
                3,
                (_) => Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _Shimmer(
                    child: _SkeletonBox(
                        width: double.infinity,
                        height: 74,
                        radius: AppRadius.md),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double radius;

  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.borderColor,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Lightweight shimmer sweep, reused by every skeleton block above.
class _Shimmer extends StatefulWidget {
  final Widget child;

  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final t = _controller.value;
            return LinearGradient(
              begin: Alignment(-1.5 + 3 * t, 0),
              end: Alignment(-0.5 + 3 * t, 0),
              colors: [
                context.borderColor,
                Colors.white.withValues(alpha: 0.9),
                context.borderColor,
              ],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------
// Create / rename dialog (kept from the original screen)
// ---------------------------------------------------------------------

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String confirmLabel;
  final String? initialValue;

  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    this.initialValue,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
