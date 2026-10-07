import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_constants.dart';

import '../../core/theme/app_theme.dart';
import '../../core/routes/app_routes.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';
import '../../providers/face_search_provider.dart';

/// UI for starting a face search: pick/take a selfie, then the buttons
/// route to Upload -> Scan Progress -> Results, backed by
/// [faceSearchProvider] for the real matching call.
class FaceSearchLandingScreen extends ConsumerWidget {
  const FaceSearchLandingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchState = ref.watch(faceSearchProvider);
    return Scaffold(
      appBar: CustomAppBar(
        title: 'Face Search',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Upload selfie',
            icon: Icon(Icons.upload_rounded),
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
              children: [
                _buildIllustrationCard(context),
                SizedBox(height: AppSpacing.lg),
                _buildScopeSwitcher(context, ref, searchState),
                _buildInfoCard(context, searchState),
                SizedBox(height: AppSpacing.lg),
                _buildUploadButtons(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIllustrationCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      padding: EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: AppColors.buttonGradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.face_retouching_natural_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Find matching photos with a selfie',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.textOnDark
                    : AppColors.text),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Lets the person choose between "only this folder/album" and the
  /// "entire library" without leaving the screen. Only shown for a
  /// scoped studio search (the icons on folder/album screens set the scope).
  Widget _buildScopeSwitcher(
      BuildContext context, WidgetRef ref, FaceSearchState state) {
    final isScoped = state.mode == FaceSearchMode.myLibrary &&
        (state.folderIdFilter != null || state.albumIdFilter != null);
    // After widening to the entire library, the notifier still remembers the
    // folder/album so the switcher can flip back to it.
    final saved = ref.read(faceSearchProvider.notifier).widenedFrom;
    final canRestore = state.mode == FaceSearchMode.myLibrary &&
        state.folderIdFilter == null &&
        state.albumIdFilter == null &&
        saved != null;
    if (!isScoped && !canRestore) return const SizedBox.shrink();

    final scope = isScoped
        ? (
            albumId: state.albumIdFilter,
            folderId: state.folderIdFilter,
            label: state.scopeLabel,
          )
        : saved!;
    final kind = scope.folderId != null ? 'folder' : 'album';

    return Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.lg),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: true,
              icon: const Icon(Icons.folder_rounded, size: 18),
              label: Text('This $kind', overflow: TextOverflow.ellipsis),
            ),
            const ButtonSegment(
              value: false,
              icon: Icon(Icons.travel_explore_rounded, size: 18),
              label: Text('Entire library'),
            ),
          ],
          selected: {isScoped},
          onSelectionChanged: (v) {
            final notifier = ref.read(faceSearchProvider.notifier);
            if (v.first) {
              notifier.useMyLibrary(
                albumId: scope.albumId,
                folderId: scope.folderId,
                scopeLabel: scope.label,
              );
            } else {
              notifier.useEntireLibrary();
            }
          },
        ),
      ),
    );
  }

  /// What this search will cover — makes it obvious whether the user
  /// came from a folder/album ("scoped") or the global icon/drawer.
  String _scopeDescription(FaceSearchState state) {
    switch (state.mode) {
      case FaceSearchMode.myLibrary:
        final label = state.scopeLabel;
        if (state.folderIdFilter != null) {
          return 'We will securely analyze your selfie and show matching photos only from the folder "${label ?? 'selected folder'}" and its sub-folders.';
        }
        if (state.albumIdFilter != null) {
          return 'We will securely analyze your selfie and show matching photos only from the album "${label ?? 'selected album'}".';
        }
        return 'We will securely analyze your selfie and show matching photos from your entire library (all albums and folders).';
      case FaceSearchMode.clientGallery:
      case FaceSearchMode.sharedGallery:
        return 'We will securely analyze your selfie and show matching photos across all your shared galleries using server-side AI face matching.';
    }
  }

  Widget _buildInfoCard(BuildContext context, FaceSearchState state) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      padding: EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.info_rounded, size: 18, color: AppColors.primary),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What happens next?',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w900,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  _scopeDescription(state),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadButtons(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload,
                  arguments: ImageSource.gallery);
            },
            icon: Icon(Icons.file_upload_outlined),
            label: Text('Upload Photo'),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md)),
              side: BorderSide(color: context.borderColor),
            ),
          ),
        ),
        SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload,
                  arguments: ImageSource.camera);
            },
            icon: Icon(Icons.camera_alt_rounded),
            label: Text('Take Photo'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }
}
