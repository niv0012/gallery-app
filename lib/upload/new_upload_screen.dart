import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart' show PhotoManager, PermissionState;
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../core/routes/app_routes.dart';
import '../core/theme/app_theme.dart';
import '../providers/album_provider.dart';
import '../providers/folder_provider.dart';
import '../services/media_picker_service.dart' show MediaContentType;
import 'new_upload_provider.dart';
import 'upload_queue_provider.dart';
import 'picked_file_info.dart';
import '../widgets/common/anchored_dropdown_field.dart';

/// Custom picker delegate that hides the "/maxAssets" part from the confirm
/// button so it shows "Confirm (3)" instead of "Confirm (3/9007199254740992)".
class _UnlimitedPickerDelegate
    extends DefaultAssetPickerBuilderDelegate<DefaultAssetPickerProvider> {
  _UnlimitedPickerDelegate({
    required super.provider,
    required super.initialPermission,
    super.locale,
  });

  @override
  Widget confirmButton(BuildContext context) {
    return ListenableBuilder(
      listenable: provider,
      builder: (_, __) {
        final p = provider;
        final bool isSelectedNotEmpty = p.isSelectedNotEmpty;
        final bool shouldAllowConfirm =
            isSelectedNotEmpty || p.previousSelectedAssets.isNotEmpty;
        return MaterialButton(
          minWidth: shouldAllowConfirm ? 48 : 20,
          height: appBarItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: theme.colorScheme.secondary,
          disabledColor: theme.splashColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
          ),
          onPressed: shouldAllowConfirm
              ? () => Navigator.maybeOf(context)?.maybePop(p.selectedAssets)
              : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          child: Text(
            isSelectedNotEmpty && !isSingleAssetMode
                ? '${textDelegate.confirm} (${p.selectedAssets.length})'
                : textDelegate.confirm,
            style: TextStyle(
              color: shouldAllowConfirm
                  ? theme.textTheme.bodyLarge?.color
                  : theme.textTheme.bodySmall?.color,
              fontSize: 17,
              fontWeight: FontWeight.normal,
            ),
            semanticsLabel: isSelectedNotEmpty && !isSingleAssetMode
                ? '${semanticsTextDelegate.confirm} (${p.selectedAssets.length})'
                : semanticsTextDelegate.confirm,
          ),
        );
      },
    );
  }
}

/// New Upload Screen — Pick → Review → Options → hands off to queue → opens Hub.
/// State is fully local via [newUploadProvider] (autoDispose) so a running upload
/// never interferes with a subsequent pick session.
class NewUploadScreen extends ConsumerStatefulWidget {
  /// Optional pre-selected album (set when coming from Album Details → Add).
  final String? initialAlbumId;

  /// Optional pre-selected folder (set when coming from Folder Details → Add).
  final String? initialFolderId;

  const NewUploadScreen({
    super.key,
    this.initialAlbumId,
    this.initialFolderId,
  });

  @override
  ConsumerState<NewUploadScreen> createState() => _NewUploadScreenState();
}

class _NewUploadScreenState extends ConsumerState<NewUploadScreen> {
  final TextEditingController _renameController = TextEditingController();
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    // Pre-seed album/folder if provided by the calling screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialAlbumId != null || widget.initialFolderId != null) {
        ref.read(newUploadProvider.notifier).updateOptions(
              albumId: widget.initialAlbumId,
              folderId: widget.initialFolderId,
            );
      }
    });
  }

  @override
  void dispose() {
    _renameController.dispose();
    super.dispose();
  }

  String _humanBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  // -------------------------------------------------------------------------
  // File picking
  // -------------------------------------------------------------------------

  Future<void> _pickFiles() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      final rawFiles = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
          'webp',
          'gif',
          'tif',
          'tiff',
          'mp4',
          'mov',
          'avi',
          'm4v',
          'mkv',
          'webm',
          '3gp',
        ],
      );

      // v12: returns List<PlatformFile>; empty means user cancelled
      if (rawFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No files were selected')),
          );
        }
        return;
      }

      final picked = <PickedFileInfo>[];
      const webStreamThreshold = 10 * 1024 * 1024; // 10 MB

      for (final f in rawFiles) {
        final sizeBytes = await _safeFileSize(f);
        Uint8List? bytes;
        Stream<Uint8List> Function()? streamFactory;

        if (kIsWeb) {
          if (sizeBytes > webStreamThreshold) {
            streamFactory = f.readAsByteStream;
          } else {
            bytes = await f.readAsBytes();
          }
        }

        picked.add(PickedFileInfo(
          name: f.name,
          path: f.path,
          sizeBytes: sizeBytes,
          bytes: bytes,
          extension: f.extension,
          streamFactory: streamFactory,
        ));
      }

      if (picked.isNotEmpty) {
        ref.read(newUploadProvider.notifier).addPickedFiles(picked);
        // Jump to options step
        if (ref.read(newUploadProvider).wizardStep == 0) {
          ref.read(newUploadProvider.notifier).setWizardStep(1);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _pickAssets() async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return _pickFiles();
    }

    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      // Request permission first so we can pass it to the custom delegate.
      final permission = await PhotoManager.requestPermissionExtend();
      final provider = DefaultAssetPickerProvider(
        requestType: RequestType.common,
        maxAssets: double.maxFinite.toInt(),
      );
      final delegate = _UnlimitedPickerDelegate(
        provider: provider,
        initialPermission: permission,
        locale: Localizations.maybeLocaleOf(context),
      );
      final List<AssetEntity>? assets =
          await AssetPicker.pickAssetsWithDelegate<
            AssetEntity, 
            AssetPathEntity, 
            DefaultAssetPickerProvider, 
            _UnlimitedPickerDelegate
          >(
        context,
        delegate: delegate,
      );

      if (assets == null || assets.isEmpty) {
        return;
      }

      // Show preparing spinner since file extraction can take time
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const Center(child: CircularProgressIndicator()),
        );
      }

      final picked = <PickedFileInfo>[];
      int duplicateCount = 0;
      final existingJobs =
          ref.read(uploadQueueProvider).valueOrNull?.jobs ?? [];

      for (final asset in assets) {
        final file = await asset.file;
        if (file == null) continue;

        final sizeBytes = await file.length();

        // On iOS `AssetEntity.title` is often null *or an empty string*
        // until it is fetched asynchronously — an empty title used to slip
        // through `??` and the file ended up as `untitled_N` with no
        // extension, which the backend then rejected as
        // `application/octet-stream`.
        var name = (asset.title ?? '').trim();
        if (name.isEmpty) {
          try {
            name = (await asset.titleAsync).trim();
          } catch (_) {}
        }
        if (name.isEmpty) {
          name = file.path.split(Platform.pathSeparator).last;
        }

        // Detect the real type from the file header and make sure the name
        // carries a matching extension (e.g. `IMG_0001` → `IMG_0001.jpg`).
        var contentType =
            await MediaContentType.forFile(path: file.path, fileName: name);
        if (contentType == MediaContentType.octetStream) {
          try {
            final mime = await asset.mimeTypeAsync;
            if (mime != null && mime.isNotEmpty) {
              contentType = mime.toLowerCase();
            }
          } catch (_) {}
        }
        if (contentType == MediaContentType.octetStream) {
          contentType = asset.type == AssetType.video
              ? 'video/quicktime'
              : 'image/jpeg';
        }
        name = MediaContentType.withExtension(name, contentType);
        final dotIdx = name.lastIndexOf('.');
        final ext = dotIdx >= 0 ? name.substring(dotIdx + 1).toLowerCase() : '';

        // Ignore RAW files completely
        if (const {'cr2', 'cr3', 'nef', 'orf', 'arw', 'dng', 'raw'}.contains(ext)) {
          continue;
        }

        // Check for duplicates
        final isDuplicate = existingJobs
            .any((j) => j.fileName == name && j.totalBytes == sizeBytes);
        if (isDuplicate) {
          duplicateCount++;
          continue;
        }

        picked.add(PickedFileInfo(
          name: name,
          path: file.path,
          sizeBytes: sizeBytes,
          bytes: null,
          extension: ext,
          streamFactory: null,
        ));
      }

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss spinner

        if (duplicateCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Skipped $duplicateCount file(s) that are already in the upload queue.'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      if (picked.isNotEmpty) {
        ref.read(newUploadProvider.notifier).addPickedFiles(picked);
        if (ref.read(newUploadProvider).wizardStep == 0) {
          ref.read(newUploadProvider.notifier).setWizardStep(1);
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss spinner
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open gallery: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<int> _safeFileSize(dynamic f) async {
    try {
      if (!kIsWeb && f.path != null) {
        return await File(f.path!).length();
      }
      return await f.length();
    } catch (_) {}
    return 0;
  }

  // -------------------------------------------------------------------------
  // Inline album / folder creation dialogs
  // -------------------------------------------------------------------------

  Future<void> _showCreateAlbumDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Album',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Album Name', hintText: 'e.g. Summer Vacation'),
              autofocus: true,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descCtrl,
              decoration:
                  const InputDecoration(labelText: 'Description (Optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (created == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        final newAlbum = await ref.read(albumProvider).createAlbum(
              name: nameCtrl.text.trim(),
              description:
                  descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
            );
        if (!mounted) return;
        ref
            .read(newUploadProvider.notifier)
            .updateOptions(albumId: newAlbum.id);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Album "${newAlbum.name}" created successfully')));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to create album: $e')));
        }
      }
    }
  }

  Future<void> _showCreateFolderDialog() async {
    final nameCtrl = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Folder',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
              labelText: 'Folder Name', hintText: 'e.g. Clients 2026'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (created == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        final newFolder = await ref
            .read(folderProvider)
            .createFolder(name: nameCtrl.text.trim());
        if (!mounted) return;
        ref
            .read(newUploadProvider.notifier)
            .updateOptions(folderId: newFolder.id);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Folder "${newFolder.name}" created successfully')));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to create folder: $e')));
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Start Upload — hand files to the queue then go to Hub
  // -------------------------------------------------------------------------

  Future<void> _startUpload() async {
    final s = ref.read(newUploadProvider);
    if (s.tempPickedFiles.isEmpty) return;

    await ref.read(uploadQueueProvider.notifier).enqueueFiles(
          files: s.tempPickedFiles,
          albumId: s.selectedAlbumId,
          folderId: s.selectedFolderId,
          renamePrefix: s.renamePrefix,
          compress: s.compress,
          wifiOnly: s.wifiOnly,
          keepOriginalQuality: s.keepOriginalQuality,
          uploadMetadata: s.uploadMetadata,
        );

    if (!mounted) return;
    // Replace this screen with the Hub so Back goes to wherever the user came from
    Navigator.of(context).pushReplacementNamed(AppRoutes.uploads);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(newUploadProvider);
    final notifier = ref.read(newUploadProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(state.wizardStep == 0 ? 'Select Files' : 'Upload Options'),
        leading: IconButton(
          icon: Icon(state.wizardStep == 0 ? Icons.close : Icons.arrow_back),
          onPressed: () {
            if (state.wizardStep == 0) {
              Navigator.of(context).pop();
            } else {
              notifier.setWizardStep(0);
            }
          },
        ),
      ),
      body: state.wizardStep == 0
          ? _buildSelectionStep(context, state, notifier, isDark)
          : _buildOptionsStep(context, state, notifier, isDark),
    );
  }

  // -------------------------------------------------------------------------
  // Step 0: Select files
  // -------------------------------------------------------------------------

  Widget _buildSelectionStep(BuildContext context, NewUploadState state,
      NewUploadNotifier notifier, bool isDark) {
    final files = state.tempPickedFiles;
    final totalSize = files.fold<int>(0, (s, f) => s + f.sizeBytes);

    return Column(
      children: [
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.cloud_upload_outlined,
                              size: 64, color: AppColors.primary),
                        ),
                        const SizedBox(height: 24),
                        Text('Upload Studio Media',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? AppColors.textOnDark
                                    : AppColors.text)),
                        const SizedBox(height: 8),
                        Text(
                          'Select high-quality images and videos to upload to your Studio Gallery.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: isDark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle,
                                    height: 1.5,
                                  ),
                        ),
                        const SizedBox(height: 32),
                        _isPicking
                            ? const CircularProgressIndicator()
                            : FilledButton.icon(
                                onPressed: _pickAssets,
                                icon: const Icon(Icons.photo_library_rounded),
                                label: const Text('Open Gallery'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 28, vertical: 14),
                                  textStyle: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: _isPicking ? null : _pickFiles,
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('Browse other files'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    // File count summary
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkSurface : Colors.white,
                        border: Border(
                            bottom: BorderSide(
                                color: isDark
                                    ? AppColors.darkBorder
                                    : Colors.grey.shade100)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_rounded,
                              size: 16,
                              color: isDark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          const SizedBox(width: 6),
                          Text(
                            '${files.length} file${files.length == 1 ? '' : 's'} · ${_humanBytes(totalSize)}',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? AppColors.textOnDark
                                    : AppColors.text),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _isPicking ? null : _pickAssets,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add more'),
                          ),
                        ],
                      ),
                    ),
                    // File list (Grid)
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: files.length,
                        itemBuilder: (ctx, i) {
                          final f = files[i];
                          final isVideo = _isVideo(f.name);
                          final unsupported = _isUnsupported(f.name);

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppColors.darkSurfaceRaised
                                      : Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  image: (!kIsWeb && f.path != null && !isVideo)
                                      ? DecorationImage(
                                          image: FileImage(File(f.path!)),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: (kIsWeb || f.path == null || isVideo)
                                    ? Center(
                                        child: Icon(
                                          isVideo
                                              ? Icons.videocam_rounded
                                              : Icons.image_rounded,
                                          color: isDark
                                              ? Colors.white54
                                              : Colors.black54,
                                          size: 32,
                                        ),
                                      )
                                    : null,
                              ),
                              if (unsupported)
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.8),
                                      borderRadius: const BorderRadius.vertical(
                                          bottom: Radius.circular(8)),
                                    ),
                                    child: const Text(
                                      'Unsupported',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () {
                                    final updated =
                                        List<PickedFileInfo>.from(files)
                                          ..removeAt(i);
                                    notifier.setPickedFiles(updated);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close_rounded,
                                        size: 16, color: Colors.white),
                                  ),
                                ),
                              ),
                              if (isVideo)
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(Icons.videocam_rounded,
                                        size: 14, color: Colors.white),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        // Bottom bar
        if (files.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: notifier.clearPickedFiles,
                      child: const Text('Clear All'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => notifier.setWizardStep(1),
                      child: const Text('Next: Options'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Step 1: Options
  // -------------------------------------------------------------------------

  Widget _buildOptionsStep(BuildContext context, NewUploadState state,
      NewUploadNotifier notifier, bool isDark) {
    final albums = ref.watch(albumProvider).allAlbums;
    final folders = ref.watch(folderProvider).folders;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Destination
                Text('Destination',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppColors.textOnDark : AppColors.text)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: AnchoredDropdownField<String?>(
                        value: state.selectedAlbumId,
                        decoration:
                            const InputDecoration(labelText: 'Select Album'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('No Album')),
                          ...albums.map((a) => DropdownMenuItem<String?>(
                              value: a.id, child: Text(a.name))),
                        ],
                        onChanged: (val) => notifier.updateOptions(
                            albumId: val, clearAlbum: val == null),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Create New Album',
                      onPressed: _showCreateAlbumDialog,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AnchoredDropdownField<String?>(
                        value: state.selectedFolderId,
                        decoration:
                            const InputDecoration(labelText: 'Select Folder'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('No Folder')),
                          ...folders.map((f) => DropdownMenuItem<String?>(
                              value: f.id, child: Text(f.name))),
                        ],
                        onChanged: (val) => notifier.updateOptions(
                            folderId: val, clearFolder: val == null),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Create New Folder',
                      onPressed: _showCreateFolderDialog,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Renaming (under Advanced)
                _SectionDivider(label: 'Advanced', isDark: isDark),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _renameController,
                  decoration: const InputDecoration(
                    labelText: 'Rename Prefix (Optional)',
                    hintText: 'e.g. Wedding_ClientA',
                  ),
                  onChanged: (val) => notifier.updateOptions(
                    renamePrefix: val.trim().isNotEmpty ? val.trim() : null,
                    clearRenamePrefix: val.trim().isEmpty,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Files will be named: Prefix (1).jpg, Prefix (2).jpg, …',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                ),

                const SizedBox(height: 20),

                // Wi-Fi only toggle
                SwitchListTile(
                  title: const Text('Upload using Wi-Fi only'),
                  subtitle:
                      const Text('Pauses uploads on cellular data networks'),
                  value: state.wifiOnly,
                  onChanged: (val) => notifier.updateOptions(wifiOnly: val),
                ),

                const SizedBox(height: 24),

                // File summary
                _FileSummary(
                    files: state.tempPickedFiles,
                    humanBytes: _humanBytes,
                    isDark: isDark),
              ],
            ),
          ),
        ),

        // Bottom action bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => notifier.setWizardStep(0),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _startUpload,
                    icon: const Icon(Icons.cloud_upload_rounded),
                    label: Text(
                        'Start Upload (${state.tempPickedFiles.length} file${state.tempPickedFiles.length == 1 ? '' : 's'})'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _isVideo(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['mp4', 'mov', 'mkv', 'webm', '3gp'].contains(ext);
  }

  bool _isUnsupported(String name) {
    final ext = name.split('.').last.toLowerCase();
    // Some formats like avi/m4v are known to be tricky or unsupported by web players
    return ['avi', 'm4v', 'wmv', 'flv'].contains(ext);
  }
}

// -------------------------------------------------------------------------
// Small helper widgets
// -------------------------------------------------------------------------

class _SectionDivider extends StatelessWidget {
  final String label;
  final bool isDark;
  const _SectionDivider({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle)),
        const SizedBox(width: 8),
        Expanded(
            child: Divider(
                color: isDark ? AppColors.darkBorder : Colors.grey.shade200)),
      ],
    );
  }
}

class _FileSummary extends StatelessWidget {
  final List<PickedFileInfo> files;
  final String Function(int) humanBytes;
  final bool isDark;
  const _FileSummary(
      {required this.files, required this.humanBytes, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    final total = files.fold<int>(0, (s, f) => s + f.sizeBytes);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurfaceRaised : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isDark ? AppColors.darkBorder : Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('${files.length} file${files.length == 1 ? '' : 's'} selected',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.textOnDark : AppColors.text)),
          Text(humanBytes(total),
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color:
                      isDark ? AppColors.subtitleOnDark : AppColors.subtitle)),
        ],
      ),
    );
  }
}
