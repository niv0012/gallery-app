import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';

import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/media_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/empty_state_card.dart';

import '../../core/utils/app_exceptions.dart';
import '../../core/theme/theme_context.dart';

enum MediaBatchAction { move, copy }

class MediaBatchActionArgs {
  final MediaBatchAction action;
  final List<String> mediaIds;

  /// Source selection context is not stored in provider for workflows.
  /// The workflow only needs the ids to move/copy.
  const MediaBatchActionArgs({
    required this.action,
    required this.mediaIds,
  });
}

class MediaCopyMoveFlowScreen extends ConsumerStatefulWidget {
  final MediaBatchActionArgs args;

  const MediaCopyMoveFlowScreen({super.key, required this.args});

  @override
  ConsumerState<MediaCopyMoveFlowScreen> createState() =>
      _MediaCopyMoveFlowScreenState();
}

class _MediaCopyMoveFlowScreenState
    extends ConsumerState<MediaCopyMoveFlowScreen> {
  String? _destinationAlbumId;
  String? _destinationFolderId;

  // Tree UI state for destination browsing.
  String? _folderSearchQuery;
  final TextEditingController _createFolderController = TextEditingController();

  bool _isCreatingFolder = false;
  bool _isBusy = false;
  String? _errorMessage;

  // Progress
  int _processed = 0;
  int _total = 0;

  @override
  void dispose() {
    _createFolderController.dispose();
    super.dispose();
  }

  void _setDestinationAlbum(String? albumId) {
    setState(() {
      _destinationAlbumId = albumId;
      _destinationFolderId = null;
    });
  }

  void _setDestinationFolder(String? folderId) {
    setState(() {
      _destinationFolderId = folderId;
    });
  }

  List<FolderModel> _filterFolders(List<FolderModel> folders) {
    final q = _folderSearchQuery?.trim().toLowerCase();
    if (q == null || q.isEmpty) return folders;
    return folders
        .where((f) => f.name.toLowerCase().contains(q))
        .toList(growable: false);
  }

  Future<void> _createFolderUnderSelectedAlbum(BuildContext context) async {
    if (_destinationAlbumId == null) return;

    final controller = _createFolderController;
    final name = controller.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _isCreatingFolder = true;
      _errorMessage = null;
    });

    try {
      // The Folder feature is nested and independent from albums.
      // We create under the currently selected destination folder if any,
      // otherwise under root.
      final parentId = _destinationFolderId;
      await ref.read(folderProvider).createFolder(
            name: name,
            parentId: parentId,
          );

      // After creating, set destination to the new folder so the user can
      // batch move/copy into it immediately.
      final created = ref.read(folderProvider).folders.lastWhere(
            (f) => f.name == name,
            orElse: () => ref.read(folderProvider).folders.last,
          );

      if (!context.mounted) return;
      setState(() {
        _destinationFolderId = created.id;
        controller.clear();
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isCreatingFolder = false);
      }
    }
  }

  Future<void> _runBatch(BuildContext context) async {
    final controller = ref.read(mediaProvider);
    final ids = widget.args.mediaIds;
    if (ids.isEmpty) return;

    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _processed = 0;
      _total = ids.length;
    });

    // Preserve selection correctly: batch operations currently depend on
    // controller selection set. Capture existing selection, set exactly the
    // passed ids for the duration of the operation, then restore it.
    final prevSelected = controller.selectedIds.toSet();
    controller.deselectAll();
    for (final id in ids) {
      controller.toggleSelected(id);
    }

    try {
      if (_destinationAlbumId == null) {
        throw const ValidationException('Select a destination album');
      }

      switch (widget.args.action) {
        case MediaBatchAction.move:
          await controller.batchMove(
            destinationAlbumId: _destinationAlbumId!,
            destinationFolderId: _destinationFolderId,
            onProgress: (processed, total) {
              if (!mounted) return;
              setState(() {
                _processed = processed;
                _total = total;
              });
            },
          );
          break;
        case MediaBatchAction.copy:
          await controller.batchCopy(
            destinationAlbumId: _destinationAlbumId!,
            destinationFolderId: _destinationFolderId,
            onProgress: (processed, total) {
              if (!mounted) return;
              setState(() {
                _processed = processed;
                _total = total;
              });
            },
          );
          break;
      }

      // Provider refresh: controller already updates internal list.
      // Still re-load to reconcile counts and filter state.
      await controller.load();

      if (!context.mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Success'),
          content: Text(
            '${ids.length} item(s) ${widget.args.action == MediaBatchAction.move ? 'moved' : 'copied'} successfully.',
          ),
          actions: [
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Done'),
            ),
          ],
        ),
      );

      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      // Restore selection (batch methods clear selection on success).
      controller.deselectAll();
      for (final id in prevSelected) {
        controller.toggleSelected(id);
      }
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);

    final destAlbumName = _destinationAlbumId == null
        ? null
        : albumState.allAlbums
            .firstWhere((a) => a.id == _destinationAlbumId,
                orElse: () => AlbumModel(
                    id: '',
                    name: '',
                    description: null,
                    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
                    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
                    photoCount: 0,
                    videoCount: 0,
                    folderCount: 0,
                    displayOrder: 0))
            .name;

    final allFolders = folderState.folders;
    final searchedFolders = _filterFolders(allFolders);

    return Scaffold(
      appBar: CustomAppBar(
        title: widget.args.action == MediaBatchAction.move
            ? 'Move Media'
            : 'Copy Media',
        showBack: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_errorMessage != null)
              Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Container(
                  padding: EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                        color: AppColors.error.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded, color: AppColors.error),
                      SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.textOnDark
                                    : AppColors.text),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _errorMessage = null),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(AppSpacing.lg),
                children: [
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    'Destination',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  SizedBox(height: AppSpacing.md),

                  // Breadcrumb (for selected destination folder)
                  if (_destinationFolderId != null) ...[
                    SizedBox(height: 6),
                    Text(
                      'Breadcrumb',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 8),
                    _BreadcrumbWidget(
                      folderId: _destinationFolderId!,
                      breadcrumb:
                          folderState.breadcrumbFor(_destinationFolderId!),
                    ),
                    SizedBox(height: AppSpacing.lg),
                  ],

                  // Album picker
                  Text(
                    'Album',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                    ),
                  ),
                  SizedBox(height: 10),
                  if (albumState.allAlbums.isEmpty)
                    const EmptyStateCard(
                      icon: Icons.album_rounded,
                      message: 'No albums available.',
                    )
                  else
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        for (final a in albumState.allAlbums)
                          ChoiceChip(
                            label: Text(a.name),
                            selected: _destinationAlbumId == a.id,
                            onSelected: (v) =>
                                _setDestinationAlbum(v ? a.id : null),
                          ),
                      ],
                    ),

                  SizedBox(height: AppSpacing.xl),

                  // Folder destination search
                  Text(
                    'Destination folder',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                    ),
                  ),
                  SizedBox(height: 10),

                  TextField(
                    decoration: InputDecoration(
                      hintText: 'Search folders…',
                      prefixIcon: Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    onChanged: (v) => setState(() => _folderSearchQuery = v),
                  ),
                  SizedBox(height: AppSpacing.md),

                  // Root option
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.block_rounded,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.subtitleOnDark
                            : AppColors.subtitle)),
                    title: Text('Root level (unfiled)'),
                    trailing: Radio<String?>(
                      value: null,
                      groupValue: _destinationFolderId,
                      onChanged: (v) => _setDestinationFolder(v),
                    ),
                    onTap: () => _setDestinationFolder(null),
                  ),

                  const Divider(height: 30),

                  if (searchedFolders.isEmpty)
                    const EmptyStateCard(
                      icon: Icons.folder_off_rounded,
                      message: 'No matching folders.',
                    )
                  else
                    ...searchedFolders.map((f) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.folder_rounded,
                              color: AppColors.primary),
                          title: Text(f.name),
                          subtitle: Text(
                            f.parentId == null
                                ? 'Root'
                                : 'Inside ${folderState.folderById(f.parentId!)?.name ?? '—'}',
                          ),
                          trailing: Radio<String?>(
                            value: f.id,
                            groupValue: _destinationFolderId,
                            onChanged: (v) => _setDestinationFolder(v),
                          ),
                          onTap: () => _setDestinationFolder(f.id),
                        )),

                  SizedBox(height: AppSpacing.xl),

                  // Create folder
                  Text(
                    'Create folder',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm),

                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _createFolderController,
                          decoration: InputDecoration(
                            hintText: 'New folder name',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: AppSpacing.sm),
                      FilledButton.icon(
                        onPressed: (_isBusy || _isCreatingFolder)
                            ? null
                            : () => _createFolderUnderSelectedAlbum(context),
                        icon: Icon(Icons.create_new_folder_rounded),
                        label: _isCreatingFolder
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text('Create'),
                      ),
                    ],
                  ),

                  if (destAlbumName != null)
                    Padding(
                      padding: EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        'Destination album: $destAlbumName',
                        style: TextStyle(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),

                  SizedBox(height: AppSpacing.xl),

                  // Batch move/copy button + progress
                  if (_isBusy) ...[
                    Container(
                      padding: EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        children: [
                          SizedBox(height: 2),
                          LinearProgressIndicator(
                            value: _total == 0 ? null : _processed / _total,
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text(
                            'Processing ${_processed.toString()} / ${_total.toString()}…',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),
                    const LoadingWidget(message: 'Please wait…'),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _runBatch(context),
                        icon: Icon(widget.args.action == MediaBatchAction.move
                            ? Icons.drive_file_move_rounded
                            : Icons.copy_all_rounded),
                        label: Text(widget.args.action == MediaBatchAction.move
                            ? 'Move ${widget.args.mediaIds.length} items'
                            : 'Copy ${widget.args.mediaIds.length} items'),
                      ),
                    ),
                  SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbWidget extends StatelessWidget {
  final String folderId;
  final List<FolderModel> breadcrumb;

  const _BreadcrumbWidget({
    required this.folderId,
    required this.breadcrumb,
  });

  @override
  Widget build(BuildContext context) {
    if (breadcrumb.isEmpty) {
      return Text('Root level (unfiled)');
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: 6,
      children: [
        for (int i = 0; i < breadcrumb.length; i++) ...[
          ActionChip(
            label: Text(breadcrumb[i].name),
            onPressed: () {
              // Breadcrumb in this flow is read-only (navigation handled by
              // folder tree list); keep UI consistent.
            },
          ),
          if (i < breadcrumb.length - 1)
            Icon(Icons.chevron_right_rounded, size: 16),
        ],
      ],
    );
  }
}
