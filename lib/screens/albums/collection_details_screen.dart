import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/gallery_collection_model.dart';

import '../../providers/gallery_collections_provider.dart';
import '../../providers/album_provider.dart';
import '../../models/album_model.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/delete_confirmation_dialog.dart';
import '../../widgets/common/snackbar_helper.dart';
import '../../widgets/common/loading_widget.dart';
import '../../core/theme/theme_context.dart';

/// Collection Details screen.
///
/// Uses the same [CustomAppBar] every other detail screen in the app
/// (Album Details, Folder Details) uses — a flat, small header with a
/// back button, the collection's name as the title, and rename/delete
/// as app-bar actions — instead of a large bespoke hero. A slim meta row
/// (item count · last updated) sits just below it. Everything below is
/// state-driven off the same [galleryCollectionsProvider] / [albumProvider]
/// used before — no business logic, routes or callbacks changed, only the
/// widgets that render them.
///
/// A collection groups *albums*, not individual photos/videos (matching
/// `app/api/routes/collections.py`'s `CollectionItem.album_id` FK into
/// the `Album` table) — so every row here is an [AlbumModel], and "Add
/// Gallery" picks from the studio's existing albums.
class CollectionDetailsScreen extends ConsumerStatefulWidget {
  final String collectionId;
  const CollectionDetailsScreen({super.key, required this.collectionId});

  @override
  ConsumerState<CollectionDetailsScreen> createState() =>
      _CollectionDetailsScreenState();
}

class _CollectionDetailsScreenState
    extends ConsumerState<CollectionDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: AppDurations.medium,
  )..forward();

  late final Animation<double> _fade =
      CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.03),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Future<void> _openRenameDialog(
    BuildContext context,
    GalleryCollectionModel collection,
  ) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextInputDialog(
        title: 'Rename Collection',
        hint: 'Collection name',
        confirmLabel: 'Save',
        initialValue: collection.name,
      ),
    );
    if (newName == null || !context.mounted) return;
    await ref.read(galleryCollectionsProvider).renameCollection(
          collectionId: collection.id,
          newName: newName,
        );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    GalleryCollectionModel collection,
  ) async {
    final confirmed = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete item?',
      message:
          'This will permanently remove "${collection.name}". The albums inside it are not deleted. This cannot be undone.',
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(galleryCollectionsProvider).deleteCollection(collection.id);
    if (!context.mounted) return;
    SnackBarHelper.showSuccess(context, '"${collection.name}" deleted');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final collectionsCtrl = ref.watch(galleryCollectionsProvider);
    final albumCtrl = ref.watch(albumProvider);

    final collection = collectionsCtrl.collectionById(widget.collectionId);

    final isLoading = collectionsCtrl.isLoading && collection == null;
    final hasError =
        !isLoading && collection == null && collectionsCtrl.lastError != null;
    final notFound = !isLoading && !hasError && collection == null;

    final galleryIds = collection?.galleryIds ?? const <String>[];
    final orderedAlbums = <AlbumModel>[];
    for (final aid in galleryIds) {
      final a = albumCtrl.allAlbums.where((am) => am.id == aid).toList();
      if (a.isNotEmpty) orderedAlbums.add(a.first);
    }

    return Scaffold(
      appBar: CustomAppBar(
        title: collection?.name ?? 'Collection',
        showBack: true,
        actions: collection == null
            ? null
            : [
                IconButton(
                  tooltip: 'Share',
                  icon: Icon(Icons.share_rounded),
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.collectionShareSettings,
                    arguments: collection.id,
                  ),
                ),
                IconButton(
                  tooltip: 'Rename',
                  icon: Icon(Icons.edit_outlined),
                  onPressed: () => _openRenameDialog(context, collection),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: Icon(Icons.delete_outline_rounded,
                      color: AppColors.error),
                  onPressed: () => _confirmDelete(context, collection),
                ),
              ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Column(
              children: [
                if (collection != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm,
                        AppSpacing.md, AppSpacing.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${galleryIds.length} '
                        '${galleryIds.length == 1 ? 'album' : 'albums'} · '
                        'Updated ${_timeAgo(collection.updatedAt)}',
                        style: TextStyle(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppDurations.fast,
                    child: isLoading
                        ? const _LoadingState(key: ValueKey('loading'))
                        : hasError
                            ? _ErrorState(
                                key: const ValueKey('error'),
                                onRetry: () => collectionsCtrl.load(),
                              )
                            : notFound
                                ? const _NotFoundState(
                                    key: ValueKey('not-found'))
                                : galleryIds.isEmpty
                                    ? _EmptyState(
                                        key: const ValueKey('empty'),
                                        onAdd: () => _showAddGallerySheet(
                                            context, ref, collection!),
                                      )
                                    : _GalleryList(
                                        key: const ValueKey('list'),
                                        collection: collection!,
                                        albums: orderedAlbums,
                                      ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: collection == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'collection_details_fab',
              onPressed: () => _showAddGallerySheet(context, ref, collection),
              icon: Icon(Icons.add_rounded),
              label: Text('Add Gallery'),
            ),
    );
  }

  Future<void> _showAddGallerySheet(
    BuildContext context,
    WidgetRef ref,
    GalleryCollectionModel collection,
  ) async {
    final albumCtrl = ref.read(albumProvider);

    final available = albumCtrl.allAlbums;

    final selected = <String>{};

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Add to ${collection.name}',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                                ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    SizedBox(height: AppSpacing.md),
                    if (available.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: Center(
                          child: Text(
                            'No albums yet — create one first.',
                            style: TextStyle(
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final crossAxisCount = (constraints.maxWidth / 130)
                                .floor()
                                .clamp(2, 6);
                            return GridView.builder(
                              itemCount: available.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 0.95,
                              ),
                              itemBuilder: (context, i) {
                                final a = available[i];
                                final already =
                                    collection.galleryIds.contains(a.id);
                                final isSelected = selected.contains(a.id);

                                final disabled = already;

                                return InkWell(
                                  onTap: () {
                                    if (disabled) return;
                                    setState(() {
                                      if (isSelected) {
                                        selected.remove(a.id);
                                      } else {
                                        selected.add(a.id);
                                      }
                                    });
                                  },
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.lg),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                              AppRadius.lg),
                                          border: Border.all(
                                            color: already
                                                ? context.borderColor
                                                : isSelected
                                                    ? AppColors.primary
                                                    : context.borderColor,
                                            width: 1,
                                          ),
                                          gradient: LinearGradient(
                                            colors: a.gradient,
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Icon(
                                                Icons.photo_library_rounded,
                                                color: Colors.white,
                                                size: 22,
                                              ),
                                              SizedBox(height: 6),
                                              Text(
                                                a.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (already)
                                        Positioned.fill(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.35),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      AppRadius.lg),
                                            ),
                                            child: Center(
                                              child: Icon(
                                                  Icons.check_circle_rounded,
                                                  color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      if (!already && isSelected)
                                        Positioned.fill(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.20),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      AppRadius.lg),
                                            ),
                                            child: Align(
                                              alignment: Alignment.topRight,
                                              child: Padding(
                                                padding: EdgeInsets.all(6),
                                                child: Icon(
                                                    Icons.check_circle_rounded,
                                                    color: Colors.white,
                                                    size: 22),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: Icon(Icons.add_rounded),
                            label: Text(
                              'Add (${selected.length})',
                            ),
                            onPressed: () async {
                              if (selected.isEmpty) {
                                Navigator.of(ctx).pop();
                                return;
                              }
                              await ref
                                  .read(galleryCollectionsProvider)
                                  .addGalleriesToCollection(
                                    collectionId: collection.id,
                                    galleryIds: selected.toList(),
                                  );
                              if (context.mounted) Navigator.of(ctx).pop();
                            },
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Album list — same reorder/remove callbacks as before, rows show each
// album's name + photo/video counts instead of a single media item's
// filename, and tapping a row opens that album's own Details screen.
// ---------------------------------------------------------------------

class _GalleryList extends ConsumerWidget {
  final GalleryCollectionModel collection;
  final List<AlbumModel> albums;

  const _GalleryList({
    super.key,
    required this.collection,
    required this.albums,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 640;
        final horizontalPadding = isWide
            ? (constraints.maxWidth - 640) / 2 + AppSpacing.lg
            : AppSpacing.md;

        return ReorderableListView.builder(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            AppSpacing.sm,
            horizontalPadding,
            AppSpacing.xxl,
          ),
          itemCount: albums.length,
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) async {
            final adjustedNewIndex =
                newIndex > oldIndex ? newIndex - 1 : newIndex;
            await ref
                .read(galleryCollectionsProvider)
                .reorderGalleryInCollection(
                  collectionId: collection.id,
                  oldIndex: oldIndex,
                  newIndex: adjustedNewIndex,
                );
          },
          itemBuilder: (context, i) {
            final a = albums[i];
            return Padding(
              key: ValueKey(a.id),
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: _GalleryRow(
                index: i,
                album: a,
                onRemove: () async {
                  await ref
                      .read(galleryCollectionsProvider)
                      .removeGalleryFromCollection(
                        collectionId: collection.id,
                        galleryId: a.id,
                      );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _GalleryRow extends StatelessWidget {
  final int index;
  final AlbumModel album;
  final VoidCallback onRemove;

  const _GalleryRow({
    required this.index,
    required this.album,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(AppRadius.md),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => Navigator.of(context).pushNamed(
          AppRoutes.adminAlbumDetails,
          arguments: album.id,
        ),
        child: Container(
          padding: EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: AppShadows.subtle,
          ),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Icon(Icons.drag_indicator_rounded,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
              ),
              SizedBox(width: AppSpacing.sm),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  gradient: LinearGradient(
                    colors: album.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(
                  Icons.photo_library_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '${album.photoCount} photo${album.photoCount == 1 ? '' : 's'} · '
                      '${album.videoCount} video${album.videoCount == 1 ? '' : 's'}',
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
              IconButton(
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: Icon(Icons.remove_circle_outline_rounded,
                    color: AppColors.error),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// States — empty, loading, error, not-found. All plain, no boxed cards.
// ---------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: AppColors.softWash,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.collections_bookmark_rounded,
                  size: 38, color: AppColors.primary),
            ),
            SizedBox(height: AppSpacing.lg),
            Text(
              'Nothing here yet',
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
              'Add albums to start building this collection.',
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
            TextButton.icon(
              onPressed: onAdd,
              icon: Icon(Icons.add_rounded, color: AppColors.primary),
              label: Text(
                'Add Gallery',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(child: LoadingWidget(message: 'Loading collection…'));
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
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
                  size: 32, color: AppColors.error),
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'Unable to load this collection',
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
            TextButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh_rounded, color: AppColors.primary),
              label: Text(
                'Retry',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotFoundState extends StatelessWidget {
  const _NotFoundState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text(
          'Collection not found.',
          style: TextStyle(
            color: (Theme.of(context).brightness == Brightness.dark
                ? AppColors.subtitleOnDark
                : AppColors.subtitle),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Rename dialog (unchanged behaviour, kept from the original screen)
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
