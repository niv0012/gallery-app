import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/media_model.dart';
import '../../models/edit_recipe.dart';
import '../../providers/media_provider.dart';
import '../../services/media_file_cache.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';

class PhotoEditorScreen extends ConsumerStatefulWidget {
  final MediaModel media;

  const PhotoEditorScreen({super.key, required this.media});

  @override
  ConsumerState<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends ConsumerState<PhotoEditorScreen> {
  int _activePanel =
      0; // 0: Crop, 1: Rotate, 2: Flip, 3: Adjust, 4: Filters, 5: Info
  EditRecipe _recipe = const EditRecipe();

  // History tracking for Undo/Redo
  final List<EditRecipe> _undoStack = [];
  final List<EditRecipe> _redoStack = [];

  // Press-and-hold original image preview toggle
  bool _showOriginal = false;

  // Source image loading state
  ui.Image? _sourceUiImage;
  bool _loadingImage = true;
  bool _savingImage = false;

  // API-backed media (MediaModel.isDisplayPathNetwork) has no local
  // dart:io path in [MediaModel.filePath] — it's downloaded once into
  // the shared [MediaFileCache] cache dir here, same pattern already
  // used by Share/Download, so the rest of this screen's crop/rotate/
  // filter rendering (which is all dart:io File-based) has a real local
  // path to work with regardless of where the media actually lives.
  static const _fileCache = MediaFileCache();
  String? _localFilePath;
  bool get _isNetworkMedia => widget.media.isDisplayPathNetwork;

  bool get _hasFile =>
      _localFilePath != null && File(_localFilePath!).existsSync();

  @override
  void initState() {
    super.initState();
    // Load existing edit recipe if present
    if (widget.media.editRecipe != null) {
      _recipe = widget.media.editRecipe!;
    }
    _loadSourceImage();
  }

  File _getSourceFile() {
    // Network media has no local ".original" sidecar file — the backend
    // owns the pre-edit backup instead (see PUT /media/{id}/file), so
    // there's nothing to look for locally beyond the cached download.
    if (_isNetworkMedia) return File(_localFilePath!);

    final backup = File('${widget.media.filePath}.original');
    if (backup.existsSync()) return backup;
    return File(widget.media.filePath);
  }

  Future<void> _loadSourceImage() async {
    _localFilePath = await _fileCache.localPathFor(widget.media);
    if (!_hasFile) {
      setState(() => _loadingImage = false);
      return;
    }
    try {
      final file = _getSourceFile();
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      setState(() {
        _sourceUiImage = frame.image;
        _loadingImage = false;
      });
    } catch (e) {
      debugPrint('Error loading source image: $e');
      setState(() => _loadingImage = false);
    }
  }

  void _setPanel(int index) {
    setState(() => _activePanel = index);
  }

  void _pushToUndo() {
    _undoStack.add(_recipe);
    _redoStack.clear();
    setState(() {});
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_recipe);
    setState(() {
      _recipe = _undoStack.removeLast();
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_recipe);
    setState(() {
      _recipe = _redoStack.removeLast();
    });
  }

  void _updateRecipe(EditRecipe newRecipe, {bool pushUndo = false}) {
    if (pushUndo) {
      _pushToUndo();
    }
    setState(() {
      _recipe = newRecipe;
    });
  }

  Future<void> _revertToOriginal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revert to original?'),
        content: Text('This will discard all edits permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Revert'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _savingImage = true);

    try {
      if (_isNetworkMedia) {
        if (widget.media.canRevert) {
          final reverted =
              await ref.read(mediaProvider).revertMediaEdits(widget.media);

          // The backend swapped in a (possibly differently-named) file —
          // drop the stale cache entry and re-download the real original.
          if (_localFilePath != null) {
            try {
              await File(_localFilePath!).delete();
            } catch (_) {
              // Best-effort; about to be replaced below anyway.
            }
          }
          _localFilePath = await _fileCache.localPathFor(reverted);
          if (_localFilePath == null) {
            throw StateError('Could not download the reverted original.');
          }
          final originalBytes = await File(_localFilePath!).readAsBytes();
          final codec = await ui.instantiateImageCodec(originalBytes);
          final frame = await codec.getNextFrame();

          setState(() {
            _recipe = const EditRecipe();
            _undoStack.clear();
            _redoStack.clear();
            _sourceUiImage = frame.image;
          });
        } else {
          // Nothing was ever destructively overwritten — only the
          // non-destructive recipe needs clearing, the file itself
          // hasn't changed, so there's no backend revert to call.
          await ref.read(mediaProvider).saveEditRecipe(
                media: widget.media,
                recipe: const EditRecipe(),
              );
          setState(() {
            _recipe = const EditRecipe();
            _undoStack.clear();
            _redoStack.clear();
          });
        }
      } else {
        final file = File(widget.media.filePath);
        final backupFile = File('${widget.media.filePath}.original');

        if (backupFile.existsSync()) {
          await backupFile.copy(file.path);
          await backupFile.delete();
        }

        // Re-read file to get original details
        final originalBytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(originalBytes);
        final frame = await codec.getNextFrame();
        final originalImage = frame.image;

        final updatedMedia = widget.media.copyWith(
          size: originalBytes.length,
          width: originalImage.width,
          height: originalImage.height,
          editRecipe: const EditRecipe(), // Reset recipe
          modifiedAt: DateTime.now(),
        );

        await ref.read(mediaProvider).addMedia(updatedMedia);

        setState(() {
          _recipe = const EditRecipe();
          _undoStack.clear();
          _redoStack.clear();
          _sourceUiImage = originalImage;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Successfully reverted to original.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Revert failed: $e')),
        );
      }
    } finally {
      setState(() => _savingImage = false);
    }
  }

  Future<void> _saveWorkflow() async {
    if (_sourceUiImage == null) return;

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Save options'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.save_rounded, color: AppColors.primary),
                  SizedBox(width: 12),
                  Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('copy'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.copy_all_rounded, color: AppColors.primary),
                  SizedBox(width: 12),
                  Text('Save as Copy',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('overwrite'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.auto_delete_rounded, color: AppColors.primary),
                  SizedBox(width: 12),
                  Text('Overwrite Original',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (action == null) return;

    if (action == 'save') {
      setState(() => _savingImage = true);
      try {
        if (_isNetworkMedia) {
          await ref.read(mediaProvider).saveEditRecipe(
                media: widget.media,
                recipe: _recipe,
              );
        } else {
          final now = DateTime.now();
          final updatedMedia = widget.media.copyWith(
            editRecipe: _recipe,
            modifiedAt: now,
          );
          await ref.read(mediaProvider).addMedia(updatedMedia);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Edits saved successfully.')),
          );
          Navigator.of(context).pop();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save edits: $e')),
          );
        }
      } finally {
        setState(() => _savingImage = false);
      }
      return;
    }

    setState(() => _savingImage = true);

    try {
      // 1. Render image in background canvas
      final renderedBytes = await _renderEditedBytes();

      // 2. Decode details
      final codec = await ui.instantiateImageCodec(renderedBytes);
      final frame = await codec.getNextFrame();
      final renderedImage = frame.image;

      final now = DateTime.now();

      if (action == 'overwrite') {
        if (_isNetworkMedia) {
          final result = await ref.read(mediaProvider).overwriteMediaFile(
                media: widget.media,
                bytes: renderedBytes,
                fileName: widget.media.fileName,
                contentType: 'image/png',
              );

          // The overwritten file may live at a new path/URL — refresh
          // the local cache so subsequent views/edits show the new bytes.
          if (_localFilePath != null) {
            try {
              await File(_localFilePath!).delete();
            } catch (_) {
              // Best-effort; about to be replaced below anyway.
            }
          }
          _localFilePath = await _fileCache.localPathFor(result);
        } else {
          // Back up original bytes first if not already done
          final backupFile = File('${widget.media.filePath}.original');
          if (!backupFile.existsSync()) {
            final sourceFile = File(widget.media.filePath);
            await sourceFile.copy(backupFile.path);
          }

          // Overwrite original file
          final file = File(widget.media.filePath);
          await file.writeAsBytes(renderedBytes);

          // Update database item
          final updatedMedia = widget.media.copyWith(
            size: renderedBytes.length,
            width: renderedImage.width,
            height: renderedImage.height,
            editRecipe: _recipe,
            modifiedAt: now,
          );

          await ref.read(mediaProvider).addMedia(updatedMedia);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Original photo overwritten successfully.')),
          );
          Navigator.of(context).pop();
        }
      } else {
        // Save as Copy
        if (_isNetworkMedia) {
          final nameWithoutExt = widget.media.fileName.contains('.')
              ? widget.media.fileName
                  .substring(0, widget.media.fileName.lastIndexOf('.'))
              : widget.media.fileName;
          final copyFileName =
              '${nameWithoutExt}_edited_${now.millisecondsSinceEpoch}.png';

          await ref.read(mediaProvider).saveEditedCopy(
                source: widget.media,
                bytes: renderedBytes,
                fileName: copyFileName,
                contentType: 'image/png',
                recipe: _recipe,
              );
        } else {
          final originalFile = File(widget.media.filePath);
          final dir = originalFile.parent.path;
          final nameWithoutExt = widget.media.fileName
              .substring(0, widget.media.fileName.lastIndexOf('.'));
          final ext = widget.media.fileName
              .substring(widget.media.fileName.lastIndexOf('.'));

          final copyPath =
              '$dir/${nameWithoutExt}_edited_${now.millisecondsSinceEpoch}$ext';
          final copyFile = File(copyPath);
          await copyFile.writeAsBytes(renderedBytes);

          // Create new MediaModel
          final newMedia = MediaModel(
            id: 'me-${now.microsecondsSinceEpoch}',
            type: MediaType.photo,
            filePath: copyPath,
            thumbnailPath: '',
            fileName:
                '${nameWithoutExt}_edited_${now.millisecondsSinceEpoch}$ext',
            albumId: widget.media.albumId,
            folderId: widget.media.folderId,
            size: renderedBytes.length,
            width: renderedImage.width,
            height: renderedImage.height,
            createdAt: now,
            modifiedAt: now,
            editRecipe: _recipe,
            isFavorite: widget.media.isFavorite,
          );

          await ref.read(mediaProvider).addMedia(newMedia);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved copy successfully.')),
          );
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save image: $e')),
        );
      }
    } finally {
      setState(() => _savingImage = false);
    }
  }

  Future<Uint8List> _renderEditedBytes() async {
    final image = _sourceUiImage!;
    final origW = image.width.toDouble();
    final origH = image.height.toDouble();

    double rotatedW = origW;
    double rotatedH = origH;
    if (_recipe.rotation == 90 || _recipe.rotation == 270) {
      rotatedW = origH;
      rotatedH = origW;
    }

    final cropL = _recipe.cropLeft * rotatedW;
    final cropT = _recipe.cropTop * rotatedH;
    final cropR = _recipe.cropRight * rotatedW;
    final cropB = _recipe.cropBottom * rotatedH;

    final targetW = (cropR - cropL).round().clamp(1, rotatedW.round());
    final targetH = (cropB - cropT).round().clamp(1, rotatedH.round());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Center crop transform offset
    canvas.translate(-cropL.toDouble(), -cropT.toDouble());

    // Rotate and flip around center
    canvas.translate(rotatedW / 2, rotatedH / 2);
    canvas.rotate(_recipe.rotation * math.pi / 180);
    canvas.scale(
        _recipe.flipHorizontal ? -1.0 : 1.0, _recipe.flipVertical ? -1.0 : 1.0);
    canvas.translate(-origW / 2, -origH / 2);

    final hasColorEdits = _recipe.hasEdits &&
        (_recipe.brightness != 0.0 ||
            _recipe.contrast != 0.0 ||
            _recipe.saturation != 0.0 ||
            _recipe.exposure != 0.0 ||
            _recipe.temperature != 0.0 ||
            (_recipe.filter != null && _recipe.filter != 'none'));
    final colorMatrix = hasColorEdits ? _recipe.combinedColorMatrix : null;

    if (_recipe.sharpen > 0.0) {
      // Draw base image with (1 + sharpen) scale
      final sharpenMatrix = [
        1.0 + _recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0 + _recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0 + _recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ];
      final combinedOriginalMatrix = colorMatrix != null
          ? EditRecipe.multiplyMatrices(sharpenMatrix, colorMatrix)
          : sharpenMatrix;

      final originalPaint = Paint()
        ..colorFilter = ColorFilter.matrix(combinedOriginalMatrix);
      canvas.drawImage(image, Offset.zero, originalPaint);

      // Draw blurred image with -sharpen scale
      final blurMatrix = [
        -_recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -_recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -_recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ];
      final combinedBlurMatrix = colorMatrix != null
          ? EditRecipe.multiplyMatrices(blurMatrix, colorMatrix)
          : blurMatrix;

      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 1.5, sigmaY: 1.5, tileMode: TileMode.clamp)
        ..colorFilter = ColorFilter.matrix(combinedBlurMatrix)
        ..blendMode = BlendMode.plus;
      canvas.drawImage(image, Offset.zero, blurPaint);
    } else {
      final paint = Paint();
      if (colorMatrix != null) {
        paint.colorFilter = ColorFilter.matrix(colorMatrix);
      }
      canvas.drawImage(image, Offset.zero, paint);
    }

    final picture = recorder.endRecording();
    final renderedImage = await picture.toImage(targetW, targetH);
    final byteData =
        await renderedImage.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingImage) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_sourceUiImage == null) {
      return Scaffold(
        appBar: const CustomAppBar(title: 'Edit Photo', showBack: true),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.image_not_supported_rounded,
                  size: 64,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
              SizedBox(height: 16),
              Text('Original image could not be loaded.'),
              SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final activeRecipe = _showOriginal ? const EditRecipe() : _recipe;

    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        title: Text('Edit Photo',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Padding(
          padding: EdgeInsets.only(left: 12),
          child: Center(
            child: IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 18),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: Icon(Icons.undo_rounded),
            onPressed: _undoStack.isNotEmpty ? _undo : null,
            color: Colors.white,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: Icon(Icons.redo_rounded),
            onPressed: _redoStack.isNotEmpty ? _redo : null,
            color: Colors.white,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Preview Box
              Expanded(
                flex: 5,
                child: GestureDetector(
                  onLongPressStart: (_) => setState(() => _showOriginal = true),
                  onLongPressEnd: (_) => setState(() => _showOriginal = false),
                  child: Container(
                    margin: EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) {
                              return _buildPreview(
                                  constraints.biggest, activeRecipe);
                            },
                          ),
                          if (_showOriginal)
                            Positioned(
                              top: AppSpacing.md,
                              left: AppSpacing.md,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.pill),
                                  border: Border.all(color: Colors.white30),
                                ),
                                child: Text(
                                  'Showing Original',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            bottom: AppSpacing.md,
                            right: AppSpacing.md,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.touch_app_rounded,
                                      size: 14, color: Colors.white70),
                                  SizedBox(width: 4),
                                  Text(
                                    'Hold preview to see before',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Control panel area
              Expanded(
                flex: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(AppRadius.lg)),
                    boxShadow: AppShadows.soft(Colors.black, opacity: 0.1),
                  ),
                  child: Column(
                    children: [
                      // Active Panel View
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: AppDurations.fast,
                          child: _buildPanelContent(),
                        ),
                      ),

                      // Secondary toolbar navigation
                      _EditorBottomToolbar(
                        activeIndex: _activePanel,
                        onPanelSelected: _setPanel,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_savingImage)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: AppColors.primary),
                    SizedBox(height: 16),
                    Text(
                      'Processing image...',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: context.surfaceColor,
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _savingImage ? null : _saveWorkflow,
                  icon: Icon(Icons.save_alt_rounded),
                  label: Text('Save Edits',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(Size containerSize, EditRecipe recipe) {
    double origW = _sourceUiImage!.width.toDouble();
    double origH = _sourceUiImage!.height.toDouble();

    // Check if swapped dimensions
    double rotatedW = origW;
    double rotatedH = origH;
    if (recipe.rotation == 90 || recipe.rotation == 270) {
      rotatedW = origH;
      rotatedH = origW;
    }

    // Fitted size bounds inside preview container
    double fitScale = math.min(
        containerSize.width / rotatedW, containerSize.height / rotatedH);
    double imgW = rotatedW * fitScale;
    double imgH = rotatedH * fitScale;

    // Normalised crop width/height
    double cropW = recipe.cropRight - recipe.cropLeft;
    double cropH = recipe.cropBottom - recipe.cropTop;

    // Dimensions of crop region in screen pixels
    double cW = cropW * imgW;
    double cH = cropH * imgH;

    // If we are currently editing the Crop bounds, we show the full bounds + draggable overlay
    // Otherwise, we crop it and scale it to fit the box
    final isCropActive = _activePanel == 0 && !_showOriginal;

    if (isCropActive) {
      return SizedBox(
        width: imgW,
        height: imgH,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Renders fully adjusted rotated/flipped source image
            Positioned.fill(
              child: _buildBaseImage(rotatedW, rotatedH, recipe),
            ),
            // Draggable Crop overlay
            Positioned.fill(
              child: _CropOverlay(
                normalizedRect: Rect.fromLTRB(
                  recipe.cropLeft,
                  recipe.cropTop,
                  recipe.cropRight,
                  recipe.cropBottom,
                ),
                size: Size(imgW, imgH),
                onChanged: (newRect) {
                  _updateRecipe(recipe.copyWith(
                    cropLeft: newRect.left,
                    cropTop: newRect.top,
                    cropRight: newRect.right,
                    cropBottom: newRect.bottom,
                  ));
                },
                onDragEnd: _pushToUndo,
              ),
            ),
          ],
        ),
      );
    } else {
      // Cropped View fitted to container
      double zoomScale =
          math.min(containerSize.width / cW, containerSize.height / cH);
      double renderDx = containerSize.width / 2 -
          (recipe.cropLeft + cropW / 2) * imgW * zoomScale;
      double renderDy = containerSize.height / 2 -
          (recipe.cropTop + cropH / 2) * imgH * zoomScale;

      return Container(
        width: containerSize.width,
        height: containerSize.height,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(color: Colors.black),
        child: Transform(
          transform: Matrix4.identity()
            ..translate(renderDx, renderDy)
            ..scale(zoomScale),
          child: Center(
            child: SizedBox(
              width: imgW,
              height: imgH,
              child: _buildBaseImage(rotatedW, rotatedH, recipe),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildBaseImage(double w, double h, EditRecipe recipe) {
    return CustomPaint(
      size: Size(w, h),
      painter: _BaseImagePainter(image: _sourceUiImage!, recipe: recipe),
    );
  }

  Widget _buildPanelContent() {
    switch (_activePanel) {
      case 0:
        return _buildCropPanel();
      case 1:
        return _buildRotatePanel();
      case 2:
        return _buildFlipPanel();
      case 3:
        return _buildAdjustmentsPanel();
      case 4:
        return _buildFiltersPanel();
      case 5:
        return _buildInfoPanel();
      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildCropPanel() {
    Widget ratioBtn(String label, double? ratio, IconData icon) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: ActionChip(
          avatar: Icon(icon, size: 16),
          label: Text(label),
          onPressed: () {
            _pushToUndo();
            if (ratio == null) {
              _updateRecipe(_recipe.copyWith(
                  cropLeft: 0.0,
                  cropTop: 0.0,
                  cropRight: 1.0,
                  cropBottom: 1.0));
            } else {
              // Calculate center aspect ratio crop bounds
              double imageRatio =
                  _sourceUiImage!.width / _sourceUiImage!.height;
              if (_recipe.rotation == 90 || _recipe.rotation == 270) {
                imageRatio = _sourceUiImage!.height / _sourceUiImage!.width;
              }

              double w = 1.0;
              double h = 1.0;
              if (imageRatio > ratio) {
                // Image is wider than desired ratio
                w = ratio / imageRatio;
              } else {
                // Image is taller than desired ratio
                h = imageRatio / ratio;
              }

              double left = (1.0 - w) / 2;
              double top = (1.0 - h) / 2;
              _updateRecipe(_recipe.copyWith(
                cropLeft: left,
                cropTop: top,
                cropRight: left + w,
                cropBottom: top + h,
              ));
            }
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 4),
          child: Text(
            'Crop Bounds',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
              'Drag corner handles to crop, or select preset aspect ratios below.',
              style: TextStyle(
                  fontSize: 12,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle))),
        ),
        const Spacer(),
        SizedBox(
          height: 60,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            children: [
              ratioBtn('Free / Reset', null, Icons.crop_free_rounded),
              ratioBtn('Square (1:1)', 1.0, Icons.crop_din_rounded),
              ratioBtn('Standard (4:3)', 4.0 / 3.0, Icons.crop_3_2_rounded),
              ratioBtn('HD (16:9)', 16.0 / 9.0, Icons.crop_16_9_rounded),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
      ],
    );
  }

  Widget _buildRotatePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: Text(
            'Rotate Image',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                _pushToUndo();
                int next = (_recipe.rotation - 90) % 360;
                if (next < 0) next += 360;
                _updateRecipe(_recipe.copyWith(rotation: next));
              },
              icon: Icon(Icons.rotate_left_rounded),
              label: Text('90° Left'),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
            ),
            SizedBox(width: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: () {
                _pushToUndo();
                int next = (_recipe.rotation + 90) % 360;
                _updateRecipe(_recipe.copyWith(rotation: next));
              },
              icon: Icon(Icons.rotate_right_rounded),
              label: Text('90° Right'),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
            ),
          ],
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildFlipPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: Text(
            'Flip / Mirror',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilterChip(
              selected: _recipe.flipHorizontal,
              onSelected: (val) {
                _pushToUndo();
                _updateRecipe(_recipe.copyWith(flipHorizontal: val));
              },
              label: Text('Flip Horizontal'),
              avatar: Icon(Icons.flip_rounded, size: 18),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            SizedBox(width: AppSpacing.lg),
            FilterChip(
              selected: _recipe.flipVertical,
              onSelected: (val) {
                _pushToUndo();
                _updateRecipe(_recipe.copyWith(flipVertical: val));
              },
              label: Text('Flip Vertical'),
              avatar: Icon(Icons.unfold_more_rounded, size: 18),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ],
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildAdjustmentsPanel() {
    Widget adjSlider({
      required String label,
      required double value,
      required ValueChanged<double> onChanged,
      required IconData icon,
      double min = -1.0,
      double max = 1.0,
    }) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 2),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle)),
            SizedBox(width: 12),
            SizedBox(
              width: 90,
              child: Text(label,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                activeColor: AppColors.primary,
                onChanged: onChanged,
                onChangeEnd: (_) => _pushToUndo(),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 2),
          child: Text(
            'Adjustments',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: ListView(
            shrinkWrap: true,
            children: [
              adjSlider(
                label: 'Brightness',
                value: _recipe.brightness,
                icon: Icons.light_mode_rounded,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(brightness: val)),
              ),
              adjSlider(
                label: 'Contrast',
                value: _recipe.contrast,
                icon: Icons.contrast_rounded,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(contrast: val)),
              ),
              adjSlider(
                label: 'Saturation',
                value: _recipe.saturation,
                icon: Icons.palette_rounded,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(saturation: val)),
              ),
              adjSlider(
                label: 'Exposure',
                value: _recipe.exposure,
                icon: Icons.exposure_rounded,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(exposure: val)),
              ),
              adjSlider(
                label: 'Temperature',
                value: _recipe.temperature,
                icon: Icons.thermostat_rounded,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(temperature: val)),
              ),
              adjSlider(
                label: 'Sharpen',
                value: _recipe.sharpen,
                icon: Icons.details_rounded,
                min: 0.0,
                max: 1.0,
                onChanged: (val) =>
                    _updateRecipe(_recipe.copyWith(sharpen: val)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFiltersPanel() {
    final List<Map<String, String>> filtersList = [
      {'name': 'none', 'label': 'Original'},
      {'name': 'grayscale', 'label': 'B&W'},
      {'name': 'sepia', 'label': 'Sepia'},
      {'name': 'vintage', 'label': 'Vintage'},
      {'name': 'cinematic', 'label': 'Cinematic'},
      {'name': 'dramatic', 'label': 'Dramatic'},
      {'name': 'cool', 'label': 'Cool'},
      {'name': 'warm', 'label': 'Warm'},
    ];

    Widget filterBtn(String name, String label) {
      final isSelected =
          _recipe.filter == name || (name == 'none' && _recipe.filter == null);

      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: GestureDetector(
          onTap: () {
            _pushToUndo();
            _updateRecipe(
                _recipe.copyWith(filter: name == 'none' ? null : name));
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color:
                        isSelected ? AppColors.primary : Colors.grey.shade300,
                    width: isSelected ? 2.5 : 1.0,
                  ),
                ),
                clipBehavior: Clip.hardEdge,
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(
                    EditRecipe(filter: name == 'none' ? null : name)
                        .combinedColorMatrix,
                  ),
                  child: Image.file(_getSourceFile(), fit: BoxFit.cover),
                ),
              ),
              SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? AppColors.primary
                      : (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 2),
          child: Text(
            'Filters',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const Spacer(),
        if (_recipe.filter != null)
          Padding(
            padding:
                EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.blur_linear_rounded,
                    size: 18,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
                SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: Text('Filter Strength',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                Expanded(
                  child: Slider(
                    value: _recipe.filterIntensity,
                    min: 0.0,
                    max: 1.0,
                    activeColor: AppColors.primary,
                    onChanged: (val) {
                      _updateRecipe(_recipe.copyWith(filterIntensity: val));
                    },
                    onChangeEnd: (_) => _pushToUndo(),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(_recipe.filterIntensity * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 105,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            itemCount: filtersList.length,
            itemBuilder: (context, i) {
              return filterBtn(
                  filtersList[i]['name']!, filtersList[i]['label']!);
            },
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildInfoPanel() {
    final hasBackup = _isNetworkMedia
        ? widget.media.canRevert
        : File('${widget.media.filePath}.original').existsSync();

    return Padding(
      padding: EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Info & Actions',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'Original Resolution: ${_sourceUiImage!.width} × ${_sourceUiImage!.height}',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle)),
          ),
          const Spacer(),
          if (hasBackup || _recipe.hasEdits)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingImage ? null : _revertToOriginal,
                icon: Icon(Icons.restore_rounded),
                label: Text('Revert to Original Photo'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  padding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            )
          else
            Center(
              child: Text(
                'No edits have been applied to revert.',
                style: TextStyle(
                    fontSize: 11,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                    fontStyle: FontStyle.italic),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _CropOverlay extends StatefulWidget {
  final Rect normalizedRect;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onDragEnd;
  final Size size;

  const _CropOverlay({
    required this.normalizedRect,
    required this.onChanged,
    required this.onDragEnd,
    required this.size,
  });

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final W = widget.size.width;
    final H = widget.size.height;
    if (W <= 0 || H <= 0) return SizedBox.shrink();

    final rect = Rect.fromLTRB(
      widget.normalizedRect.left * W,
      widget.normalizedRect.top * H,
      widget.normalizedRect.right * W,
      widget.normalizedRect.bottom * H,
    );

    Widget buildCorner({
      required bool top,
      required bool left,
      required void Function(DragUpdateDetails) onDrag,
    }) {
      return Positioned(
        left: left ? rect.left - 15 : rect.right - 15,
        top: top ? rect.top - 15 : rect.bottom - 15,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _isDragging = true),
          onPanUpdate: onDrag,
          onPanEnd: (_) {
            setState(() => _isDragging = false);
            widget.onDragEnd();
          },
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment(left ? -0.5 : 0.5, top ? -0.5 : 0.5),
            color: Colors.transparent,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _CropOverlayPainter(
              normalizedRect: widget.normalizedRect,
              showGrid: _isDragging,
            ),
          ),
        ),
        Positioned(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: (details) {
              double dx = details.delta.dx / W;
              double dy = details.delta.dy / H;
              double width = widget.normalizedRect.width;
              double height = widget.normalizedRect.height;
              double newLeft =
                  (widget.normalizedRect.left + dx).clamp(0.0, 1.0 - width);
              double newTop =
                  (widget.normalizedRect.top + dy).clamp(0.0, 1.0 - height);
              widget.onChanged(Rect.fromLTRB(
                  newLeft, newTop, newLeft + width, newTop + height));
            },
            onPanEnd: (_) {
              setState(() => _isDragging = false);
              widget.onDragEnd();
            },
            child: SizedBox.expand(),
          ),
        ),
        buildCorner(
          top: true,
          left: true,
          onDrag: (details) {
            double dx = details.delta.dx / W;
            double dy = details.delta.dy / H;
            double newLeft = (widget.normalizedRect.left + dx)
                .clamp(0.0, widget.normalizedRect.right - 0.1);
            double newTop = (widget.normalizedRect.top + dy)
                .clamp(0.0, widget.normalizedRect.bottom - 0.1);
            widget.onChanged(Rect.fromLTRB(newLeft, newTop,
                widget.normalizedRect.right, widget.normalizedRect.bottom));
          },
        ),
        buildCorner(
          top: true,
          left: false,
          onDrag: (details) {
            double dx = details.delta.dx / W;
            double dy = details.delta.dy / H;
            double newRight = (widget.normalizedRect.right + dx)
                .clamp(widget.normalizedRect.left + 0.1, 1.0);
            double newTop = (widget.normalizedRect.top + dy)
                .clamp(0.0, widget.normalizedRect.bottom - 0.1);
            widget.onChanged(Rect.fromLTRB(widget.normalizedRect.left, newTop,
                newRight, widget.normalizedRect.bottom));
          },
        ),
        buildCorner(
          top: false,
          left: true,
          onDrag: (details) {
            double dx = details.delta.dx / W;
            double dy = details.delta.dy / H;
            double newLeft = (widget.normalizedRect.left + dx)
                .clamp(0.0, widget.normalizedRect.right - 0.1);
            double newBottom = (widget.normalizedRect.bottom + dy)
                .clamp(widget.normalizedRect.top + 0.1, 1.0);
            widget.onChanged(Rect.fromLTRB(newLeft, widget.normalizedRect.top,
                widget.normalizedRect.right, newBottom));
          },
        ),
        buildCorner(
          top: false,
          left: false,
          onDrag: (details) {
            double dx = details.delta.dx / W;
            double dy = details.delta.dy / H;
            double newRight = (widget.normalizedRect.right + dx)
                .clamp(widget.normalizedRect.left + 0.1, 1.0);
            double newBottom = (widget.normalizedRect.bottom + dy)
                .clamp(widget.normalizedRect.top + 0.1, 1.0);
            widget.onChanged(Rect.fromLTRB(widget.normalizedRect.left,
                widget.normalizedRect.top, newRight, newBottom));
          },
        ),
      ],
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect normalizedRect;
  final bool showGrid;

  _CropOverlayPainter({required this.normalizedRect, required this.showGrid});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      normalizedRect.left * size.width,
      normalizedRect.top * size.height,
      normalizedRect.right * size.width,
      normalizedRect.bottom * size.height,
    );

    final paintDim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), paintDim);
    canvas.drawRect(
        Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), paintDim);
    canvas.drawRect(
        Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), paintDim);
    canvas.drawRect(
        Rect.fromLTRB(0, rect.bottom, size.width, size.height), paintDim);

    final paintBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(rect, paintBorder);

    if (showGrid) {
      final paintGrid = Paint()
        ..color = Colors.white54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;

      final wThird = rect.width / 3;
      final hThird = rect.height / 3;

      canvas.drawLine(Offset(rect.left + wThird, rect.top),
          Offset(rect.left + wThird, rect.bottom), paintGrid);
      canvas.drawLine(Offset(rect.left + wThird * 2, rect.top),
          Offset(rect.left + wThird * 2, rect.bottom), paintGrid);

      canvas.drawLine(Offset(rect.left, rect.top + hThird),
          Offset(rect.right, rect.top + hThird), paintGrid);
      canvas.drawLine(Offset(rect.left, rect.top + hThird * 2),
          Offset(rect.right, rect.top + hThird * 2), paintGrid);
    }
  }

  @override
  bool shouldRepaint(_CropOverlayPainter oldDelegate) =>
      oldDelegate.normalizedRect != normalizedRect ||
      oldDelegate.showGrid != showGrid;
}

class _EditorBottomToolbar extends StatelessWidget {
  final int activeIndex;
  final ValueChanged<int> onPanelSelected;

  const _EditorBottomToolbar({
    required this.activeIndex,
    required this.onPanelSelected,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn({
      required int index,
      required IconData icon,
      required String text,
    }) {
      final isActive = activeIndex == index;
      return Expanded(
        child: IconButton(
          onPressed: () => onPanelSelected(index),
          icon: Icon(icon),
          tooltip: text,
          color: isActive
              ? AppColors.primary
              : (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle),
          iconSize: 22,
          style: IconButton.styleFrom(
            backgroundColor:
                isActive ? AppColors.primary.withValues(alpha: 0.12) : null,
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          btn(index: 0, icon: Icons.crop_rounded, text: 'Crop'),
          btn(index: 1, icon: Icons.rotate_right_rounded, text: 'Rotate'),
          btn(index: 2, icon: Icons.flip_camera_android_rounded, text: 'Flip'),
          btn(index: 3, icon: Icons.tune_rounded, text: 'Adjust'),
          btn(index: 4, icon: Icons.auto_awesome_rounded, text: 'Filters'),
          btn(index: 5, icon: Icons.info_outline_rounded, text: 'Info'),
        ],
      ),
    );
  }
}

class _BaseImagePainter extends CustomPainter {
  final ui.Image image;
  final EditRecipe recipe;

  _BaseImagePainter({
    required this.image,
    required this.recipe,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double origW = image.width.toDouble();
    final double origH = image.height.toDouble();

    canvas.save();

    // Center transformations in the allotted painter canvas size
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(recipe.rotation * math.pi / 180);
    canvas.scale(
        recipe.flipHorizontal ? -1.0 : 1.0, recipe.flipVertical ? -1.0 : 1.0);

    // Fit original bounds correctly into size dimensions
    double drawW = (recipe.rotation == 90 || recipe.rotation == 270)
        ? size.height
        : size.width;
    double drawH = (recipe.rotation == 90 || recipe.rotation == 270)
        ? size.width
        : size.height;

    canvas.scale(drawW / origW, drawH / origH);
    canvas.translate(-origW / 2, -origH / 2);

    final paint = Paint();
    final hasColorEdits = recipe.hasEdits &&
        (recipe.brightness != 0.0 ||
            recipe.contrast != 0.0 ||
            recipe.saturation != 0.0 ||
            recipe.exposure != 0.0 ||
            recipe.temperature != 0.0 ||
            (recipe.filter != null && recipe.filter != 'none'));

    final colorMatrix = hasColorEdits ? recipe.combinedColorMatrix : null;

    if (recipe.sharpen > 0.0) {
      // Draw base image with (1 + sharpen) scale
      final sharpenMatrix = [
        1.0 + recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0 + recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0 + recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ];
      final combinedOriginalMatrix = colorMatrix != null
          ? EditRecipe.multiplyMatrices(sharpenMatrix, colorMatrix)
          : sharpenMatrix;

      final originalPaint = Paint()
        ..colorFilter = ColorFilter.matrix(combinedOriginalMatrix);
      canvas.drawImage(image, Offset.zero, originalPaint);

      // Draw blurred image with -sharpen scale
      final blurMatrix = [
        -recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -recipe.sharpen,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ];
      final combinedBlurMatrix = colorMatrix != null
          ? EditRecipe.multiplyMatrices(blurMatrix, colorMatrix)
          : blurMatrix;

      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 1.5, sigmaY: 1.5, tileMode: TileMode.clamp)
        ..colorFilter = ColorFilter.matrix(combinedBlurMatrix)
        ..blendMode = BlendMode.plus;
      canvas.drawImage(image, Offset.zero, blurPaint);
    } else {
      if (colorMatrix != null) {
        paint.colorFilter = ColorFilter.matrix(colorMatrix);
      }
      canvas.drawImage(image, Offset.zero, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_BaseImagePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.recipe != recipe;
}
