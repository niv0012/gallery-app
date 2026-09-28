import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/media_format_utils.dart';
import '../../models/media_model.dart';
import '../../providers/trash_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/grid_columns_button.dart';
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
    final deletedMedia = ref.watch(trashProvider);

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Trash',
        showBack: true,
        actions: [
          if (deletedMedia.isNotEmpty)
            GridColumnsButton(
              columns: _columns ?? _calculateCrossAxisCount(MediaQuery.sizeOf(context).width),
              onChanged: (c) => setState(() => _columns = c),
            ),
          if (deletedMedia.isNotEmpty)
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
      body: deletedMedia.isEmpty
          ? _buildEmptyState(context)
          : LayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount =
                    _columns ?? _calculateCrossAxisCount(constraints.maxWidth);
                return GridView.builder(
                  padding: EdgeInsets.all(AppSpacing.md),
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: AppSpacing.md,
                    mainAxisSpacing: AppSpacing.md,
                    childAspectRatio: crossAxisCount == 1 ? 1.5 : 0.8,
                  ),
                  itemCount: deletedMedia.length,
                  itemBuilder: (context, index) {
                    final media = deletedMedia[index];
                    return _TrashItemCard(
                        media: media, compact: crossAxisCount >= 4);
                  },
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
  final MediaModel media;

  /// Dense grids (4+ columns) show an icon-only Restore button so the
  /// action row doesn't overflow the narrow tile.
  final bool compact;

  const _TrashItemCard({required this.media, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sizeStr = MediaFormatUtils.formatFileSize(media.size);

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
                      media.type == MediaType.photo ? 'PHOTO' : 'VIDEO',
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
                                ref.read(trashProvider.notifier).restore(media.id),
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
                              ref.read(trashProvider.notifier).restore(media.id),
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
                  media.fileName,
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
                  sizeStr,
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

  /// Shared thumbnail widget: handles local files, backend `file_url` /
  /// `thumbnail_url`, videos and the gradient placeholder. The old
  /// `Image.file`-only code showed nothing for API-sourced media.
  Widget _buildThumbnail() => MediaThumb(media: media);

  void _confirmDeletePermanently(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDeleteConfirmationDialog(
      context: context,
      title: 'Delete item?',
      message:
          'Do you want to permanently delete "${media.fileName}"? This cannot be undone.',
    );
    if (!context.mounted) return;
    if (confirmed) {
      await ref.read(trashProvider.notifier).deletePermanently(media.id);
      if (context.mounted) {
        SnackBarHelper.showSuccess(
            context, '"${media.fileName}" permanently deleted');
      }
    }
  }
}
