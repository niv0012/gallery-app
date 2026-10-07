import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/folder_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/anchored_dropdown_field.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../repositories/album_repository.dart';
import '../../widgets/folders/safe_delete_dialog.dart';

/// Admin-only Edit Album — reached from [AlbumDetailsScreen]. Mirrors
/// [RenameFolderScreen] / [MoveFolderScreen]'s validated-form + `_initialized`
/// pattern: album name/description/folder can all be changed here, and
/// wires into [AlbumListController.updateAlbum] (previously a
/// "Phase 3" placeholder that never touched the provider).
class EditAlbumScreen extends ConsumerStatefulWidget {
  final String albumId;

  const EditAlbumScreen({super.key, required this.albumId});

  @override
  ConsumerState<EditAlbumScreen> createState() => _EditAlbumScreenState();
}

class _EditAlbumScreenState extends ConsumerState<EditAlbumScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descController = TextEditingController();

  // Loaded once from the album on the first build, then left alone so
  // in-progress edits survive unrelated provider rebuilds (e.g. another
  // album's favorite toggle) instead of being silently overwritten —
  // the bug in the previous "load every build" version of this screen.
  bool _initialized = false;
  String? _selectedFolderId;
  String? _error;
  bool _isSaving = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    // Eagerly load folders so the folder-assignment picker is populated
    // even when this screen is opened before the Folders screen has been
    // visited (i.e. folderProvider hasn't fetched yet).
    Future.microtask(() {
      if (!mounted) return;
      final fs = ref.read(folderProvider);
      if (fs.folders.isEmpty && !fs.isLoading) fs.load();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _save(AlbumModel album) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final controller = ref.read(albumProvider);
    try {
      await controller.updateAlbum(
        id: album.id,
        name: _nameController.text,
        description: _descController.text,
        clearDescription: _descController.text.trim().isEmpty,
        folderId: _selectedFolderId,
        clearFolder: _selectedFolderId == null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album updated')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmDelete(AlbumModel album) async {
    final albumRepo = ref.read(albumRepositoryProvider);
    final mode = await showSafeDeleteDialog(
      context: context,
      itemName: album.name,
      getPreview: (mode) => albumRepo.previewDeleteAlbum(album.id, mode: mode),
    );

    if (mode == null) return;

    setState(() => _isDeleting = true);
    try {
      await ref.read(albumProvider).deleteAlbum(album.id, mode: mode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${album.name}" deleted')),
      );
      final nav = Navigator.of(context);
      nav.pop();
      if (nav.canPop()) nav.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);
    final album = _findAlbum(albumState.allAlbums, widget.albumId);

    if (album == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Edit Album', showBack: true),
        body: Center(child: Text('Album not found')),
      );
    }

    if (!_initialized) {
      _nameController.text = album.name;
      _descController.text = album.description ?? '';
      _selectedFolderId = album.folderId;
      _initialized = true;
    }

    final busy = _isSaving || _isDeleting;

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Edit Album',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Delete Album',
            onPressed: busy ? null : () => _confirmDelete(album),
            icon: _isDeleting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.red),
                  )
                : Icon(Icons.delete_outline_rounded, color: Colors.red),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: constraints.maxHeight, maxWidth: 520),
                    child: Form(
                      key: _formKey,
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_error != null) ...[
                              Text(
                                _error!,
                                style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: AppSpacing.sm),
                            ],
                            CustomTextField(
                              label: 'Album name',
                              icon: Icons.photo_album_rounded,
                              controller: _nameController,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Album name is required'
                                  : null,
                            ),
                            SizedBox(height: AppSpacing.md),
                            CustomTextField(
                              label: 'Description (optional)',
                              icon: Icons.notes_rounded,
                              controller: _descController,
                              maxLines: 3,
                            ),
                            SizedBox(height: AppSpacing.md),
                            if (folderState.isLoading &&
                                folderState.folders.isEmpty)
                              InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Folder',
                                  prefixIcon:
                                      Icon(Icons.folder_outlined, size: 20),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                    SizedBox(width: AppSpacing.sm),
                                    Text(
                                      'Loading folders…',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: (Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? AppColors.subtitleOnDark
                                            : AppColors.subtitle),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              AnchoredDropdownField<String?>(
                                key: ValueKey(_selectedFolderId),
                                value: _selectedFolderId,
                                decoration: const InputDecoration(
                                  labelText: 'Folder (tap to assign)',
                                  prefixIcon:
                                      Icon(Icons.folder_outlined, size: 20),
                                  helperText: 'Move this album into a folder',
                                ),
                                items: [
                                  const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('No folder — unassigned')),
                                  ...folderState.folders.map(
                                    (FolderModel f) =>
                                        DropdownMenuItem<String?>(
                                      value: f.id,
                                      child: Text(
                                        f.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged: (v) =>
                                    setState(() => _selectedFolderId = v),
                              ),
                            SizedBox(height: AppSpacing.sm),
                            Text(
                              '${album.photoCount} photos • ${album.videoCount} videos — updated ${_relativeTime(album.updatedAt)}',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.subtitleOnDark
                                      : AppColors.subtitle)),
                            ),
                            const Spacer(),
                            SizedBox(height: AppSpacing.lg),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: busy
                                        ? null
                                        : () =>
                                            Navigator.of(context).maybePop(),
                                    child: Text('Cancel'),
                                  ),
                                ),
                                SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  flex: 2,
                                  child: GradientButton(
                                    label: 'Save Changes',
                                    isLoading: _isSaving,
                                    onPressed: busy ? null : () => _save(album),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
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

AlbumModel? _findAlbum(List<AlbumModel> albums, String id) {
  for (final a in albums) {
    if (a.id == id) return a;
  }
  return null;
}

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inDays >= 1) return '${diff.inDays}d ago';
  if (diff.inHours >= 1) return '${diff.inHours}h ago';
  if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
  return 'just now';
}
