import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/face_search_result_model.dart';
import '../../models/media_model.dart';
import '../../models/face_model.dart';
import '../../providers/face_search_provider.dart';
import '../../providers/media_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/media/media_thumb.dart';
import '../media/image_viewer_screen.dart';
import '../media/video_player_screen.dart';

class FaceSearchResultsScreen extends ConsumerWidget {
  const FaceSearchResultsScreen({super.key});

  void _openMedia(BuildContext context, List<MediaModel> allMedia, int index,
      {required bool readOnly}) {
    final media = allMedia[index];
    final allIds = allMedia.map((m) => m.id).toList();

    if (media.type == MediaType.video) {
      Navigator.of(context).pushNamed(
        AppRoutes.videoPlayer,
        arguments: VideoPlayerArgs(
          mediaId: media.id,
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: allMedia,
        ),
      );
    } else {
      Navigator.of(context).pushNamed(
        AppRoutes.imageViewer,
        arguments: ImageViewerArgs(
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: allMedia,
          // Matches from a client/shared gallery belong to a studio the
          // viewer doesn't own — hide Move/Copy/Rename/Delete/Edit there.
          readOnly: readOnly,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(faceSearchProvider);
    // Watch the main media provider so favorite / rename / move / edit /
    // delete done from the viewer are reflected here, and deleted photos
    // disappear from the results instead of lingering as broken tiles.
    final live = ref.watch(mediaProvider);
    final gone = live.deletedIds;
    final results = <FaceSearchResultModel>[
      for (final r in state.searchResults)
        if (!gone.contains(r.media.id))
          FaceSearchResultModel(
            media: live.byId(r.media.id) ?? r.media,
            similarity: r.similarity,
          ),
    ];

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Face Search Results',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Search Again',
            icon: Icon(Icons.refresh_rounded),
            onPressed: () {
              ref.read(faceSearchProvider.notifier).reset();
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.faceSearchLanding,
                (route) => route.isFirst,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ScopeSummary(state: state, count: results.length),
            if (state.hasMultipleFaces) _FacePicker(state: state),
            Expanded(
              child: state.isProcessing
                  ? const Center(child: CircularProgressIndicator())
                  : results.isEmpty
                      ? _buildEmptyState(state)
                      : _buildGrid(context, results,
                          readOnly: state.mode != FaceSearchMode.myLibrary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(FaceSearchState state) {
    final scoped =
        state.folderIdFilter != null || state.albumIdFilter != null;
    return Padding(
      padding: EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: EmptyStateCard(
          icon: Icons.search_off_rounded,
          message: state.error ??
              (scoped
                  ? 'No matching photos found in "${state.scopeLabel ?? 'this folder/album'}".\nTry the entire library, or a clearer front-facing selfie.\nPhotos uploaded recently may still be getting indexed.'
                  : 'No matching photos found.\nTry a different selfie, or a clearer front-facing one.\nPhotos uploaded recently may still be getting indexed.'),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<FaceSearchResultModel> results,
      {required bool readOnly}) {
    final mediaList = results.map((r) => r.media).toList();
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
            childAspectRatio: 1.0,
          ),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            final media = result.media;
            final isVideo = media.type == MediaType.video;

            return GestureDetector(
              onTap: () =>
                  _openMedia(context, mediaList, index, readOnly: readOnly),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaThumb(media: media, fit: BoxFit.cover),
                    if (isVideo)
                      Positioned(
                        bottom: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One-line header: what was searched and how many photos matched.
class _ScopeSummary extends StatelessWidget {
  final FaceSearchState state;
  final int count;
  const _ScopeSummary({required this.state, required this.count});

  @override
  Widget build(BuildContext context) {
    final String where;
    if (state.mode == FaceSearchMode.myLibrary) {
      if (state.folderIdFilter != null) {
        where = 'in folder "${state.scopeLabel ?? ''}"';
      } else if (state.albumIdFilter != null) {
        where = 'in album "${state.scopeLabel ?? ''}"';
      } else {
        where = 'in your entire library';
      }
    } else {
      where = 'in shared galleries';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '$count photo${count == 1 ? '' : 's'} matched $where',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.subtitleOnDark
                : AppColors.subtitle,
          ),
        ),
      ),
    );
  }
}

/// Shown when the selfie contains more than one face: lets the person
/// pick WHICH face to search for (the backend defaults to the largest).
/// The provider already supported this via `searchWithFaceIndex`, but no
/// screen ever exposed it.
class _FacePicker extends ConsumerStatefulWidget {
  final FaceSearchState state;
  const _FacePicker({required this.state});

  @override
  ConsumerState<_FacePicker> createState() => _FacePickerState();
}

class _FacePickerState extends ConsumerState<_FacePicker> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final file = widget.state.selectedSelfie;
    if (file == null) return;
    final Uint8List bytes = await file.readAsBytes();
    final img = await decodeImageFromList(bytes);
    if (mounted) setState(() => _image = img);
  }

  @override
  Widget build(BuildContext context) {
    final faces = widget.state.detectedFaces;
    final selected = widget.state.searchedFaceIndex;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Multiple people found in your photo — tap to search for someone else',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: faces.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final face = faces[i];
                final isSelected = face.faceIndex == selected;
                return InkWell(
                  borderRadius: BorderRadius.circular(32),
                  onTap: widget.state.isProcessing || isSelected
                      ? null
                      : () => ref
                          .read(faceSearchProvider.notifier)
                          .searchWithFaceIndex(face.faceIndex),
                  child: Container(
                    width: 64,
                    height: 64,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : Colors.grey.withValues(alpha: 0.4),
                        width: isSelected ? 3 : 1.5,
                      ),
                    ),
                    child: ClipOval(
                      child: _image == null
                          ? const ColoredBox(color: Colors.black12)
                          : CustomPaint(
                              painter: _FaceCropPainter(_image!, face.box),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints just the face's bounding box (with a little padding) from the
/// decoded selfie, scaled to fill the circle.
class _FaceCropPainter extends CustomPainter {
  final ui.Image image;
  final FaceBoxPixels box;
  _FaceCropPainter(this.image, this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final padX = box.width * 0.25;
    final padY = box.height * 0.25;
    final src = Rect.fromLTRB(
      (box.left - padX).clamp(0, image.width).toDouble(),
      (box.top - padY).clamp(0, image.height).toDouble(),
      (box.right + padX).clamp(0, image.width).toDouble(),
      (box.bottom + padY).clamp(0, image.height).toDouble(),
    );
    if (src.isEmpty) return;
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FaceCropPainter old) =>
      old.image != image || old.box != box;
}
