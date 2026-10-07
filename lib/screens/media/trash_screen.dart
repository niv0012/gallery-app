import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../models/trash_item.dart';
import '../../providers/trash_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/grid_columns_button.dart';
import '../../widgets/common/pinch_zoom_grid.dart';
import '../../widgets/media/media_thumb.dart';
import '../../widgets/common/delete_confirmation_dialog.dart';
import '../../widgets/common/snackbar_helper.dart';
import '../../core/theme/theme_context.dart';

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  /// null = pick automatically from the screen width; otherwise the
  /// column count chosen in the app-bar (1 = list).
  int? _columns;

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(trashProvider);

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Trash',
        showBack: true,
        actions: [
          if (items.isNotEmpty)
            GridColumnsButton(
              columns: _columns ?? _calculateCrossAxisCount(MediaQuery.sizeOf(context).width),
              onChanged: (c) => setState(() => _columns = c),
            ),
          if (items.isNotEmpty)
            TextButton(
              onPressed: () => _confirmEmptyTrash(context, ref),
              child: Text(
                'Empty Trash',
                style: TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5),
              ),
            ),
        ],
      ),
      body: items.isEmpty
          ? _buildEmptyState(context)
          : LayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount =
                    _columns ?? _calculateCrossAxisCount(constraints.maxWidth);
                return PinchZoomGrid(
                  onZoomIn: () {
                    if (crossAxisCount > 1) setState(() => _columns = crossAxisCount - 1);
                  },
                  onZoomOut: () {
                    if (crossAxisCount < 8) setState(() => _columns = crossAxisCount + 1);
                  },
                  child: GridView.builder(
                    padding: EdgeInsets.all(AppSpacing.md),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: AppSpacing.md,
                      mainAxisSpacing: AppSpacing.md,
                      childAspectRatio: crossAxisCount == 1 ? 1.5 : 0.8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return _TrashItemCard(
                          item: item, compact: crossAxisCount >= 4);
                    },
                  ),
                );
              },
            ),
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.delete_sweep_rounded,
              color: AppColors.primary,
              size: 56,
            ),
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            'Trash is empty',
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textOnDark
                  : AppColors.text),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Deleted items will appear here.',
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEmptyTrash(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete item?',
      message:
          'This will permanently delete all items in trash. This action cannot be undone.',
      confirmText: 'Empty All',
    );
    if (!context.mounted) return;
    if (confirmed) {
      await ref.read(trashProvider.notifier).emptyTrash();
      if (context.mounted) {
        SnackBarHelper.showSuccess(context, 'Trash emptied successfully');
      }
    }
  }
}

class _TrashItemCard extends ConsumerWidget {
  final TrashItem item;

  /// Dense grids (4+ columns) show an icon-only Restore button so the
  /// action row doesn't overflow the narrow tile.
  final bool compact;

  const _TrashItemCard({required this.item, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: (Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurfaceRaised
            : AppColors.surfaceElevated),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildThumbnail(),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black26, Colors.black87],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _getTypeLabel(),
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 4,
                  right: 4,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (compact)
                          IconButton(
                            tooltip: 'Restore',
                            onPressed: () =>
                                ref.read(trashProvider.notifier).restore(item.id),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: AppColors.primary,
                              minimumSize: const Size(24, 24),
                              padding: const EdgeInsets.all(4),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            icon: Icon(Icons.settings_backup_restore_rounded,
                                size: 14),
                          )
                        else
                        ElevatedButton.icon(
                          onPressed: () =>
                              ref.read(trashProvider.notifier).restore(item.id),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.primary,
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(60, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            elevation: 0,
                          ),
                          icon: Icon(Icons.settings_backup_restore_rounded,
                              size: 12),
                          label: Text('Restore',
                              style: TextStyle(
                                  fontSize: 10.5, fontWeight: FontWeight.bold)),
                        ),
                        if (item is TrashedMediaItem) ...[
                          SizedBox(width: compact ? 4 : 8),
                          IconButton(
                            onPressed: () =>
                                _confirmDeletePermanently(context, ref),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.red.withValues(alpha: 0.2),
                              foregroundColor: Colors.redAccent,
                              minimumSize: const Size(24, 24),
                              padding: const EdgeInsets.all(4),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            icon: Icon(Icons.delete_forever_rounded, size: 14),
                          ),
                        ]
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text),
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
                SizedBox(height: 2),
                Text(
                  _getSubLabel(),
                  style: TextStyle(
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getTypeLabel() {
    final i = item;
    if (i is TrashedMediaItem) {
      return i.media.type == MediaType.photo ? 'PHOTO' : 'VIDEO';
    } else if (i is TrashedFolderItem) {
      return 'FOLDER';
    } else if (i is TrashedAlbumItem) {
      return 'ALBUM';
    }
    return '';
  }

  String _getSubLabel() {
    final i = item;
    if (i is TrashedMediaItem) {
      return MediaFormatUtils.formatFileSize(i.media.size);
    } else if (i is TrashedFolderItem) {
      return '${i.daysLeft} days left';
    } else if (i is TrashedAlbumItem) {
      return '${i.daysLeft} days left';
    }
    return '';
  }

  Widget _buildThumbnail() {
    final i = item;
    if (i is TrashedMediaItem) {
      return MediaThumb(media: i.media);
    } else if (i is TrashedFolderItem) {
      return Container(
        color: AppColors.primary.withValues(alpha: 0.1),
        child: const Icon(Icons.folder_rounded, size: 48, color: AppColors.primary),
      );
    } else if (i is TrashedAlbumItem) {
      return Container(
        color: AppColors.secondary.withValues(alpha: 0.1),
        child: const Icon(Icons.photo_album_rounded, size: 48, color: AppColors.secondary),
      );
    }
    return const SizedBox();
  }

  void _confirmDeletePermanently(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete item?',
      message:
          'Do you want to permanently delete "${item.name}"? This cannot be undone.',
    );
    if (!context.mounted) return;
    if (confirmed) {
      await ref.read(trashProvider.notifier).deletePermanently(item.id);
      if (context.mounted) {
        SnackBarHelper.showSuccess(
            context, '"${item.name}" permanently deleted');
      }
    }
  }
}
