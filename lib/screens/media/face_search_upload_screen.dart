import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../core/theme/theme_context.dart';

/// Step 2 — Upload flow UI for Face Search.
///
/// Picks/captures a selfie locally, then hands it to
/// [FaceSearchScanProgressScreen] which runs the real match via
/// [faceSearchProvider].
///
/// Navigation:
/// - Landing -> Upload
/// - Continue -> Scan Progress -> Results
class FaceSearchUploadScreen extends StatefulWidget {
  const FaceSearchUploadScreen({super.key});

  @override
  State<FaceSearchUploadScreen> createState() => _FaceSearchUploadScreenState();
}

class _FaceSearchUploadScreenState extends State<FaceSearchUploadScreen> {
  final ImagePicker _picker = ImagePicker();
  XFile? _pickedFile;

  Future<void> _pickFromGallery() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (!mounted) return;
    if (file == null) return;
    setState(() => _pickedFile = file);
  }

  Future<void> _captureFromCamera() async {
    final file = await _picker.pickImage(source: ImageSource.camera);
    if (!mounted) return;
    if (file == null) return;
    setState(() => _pickedFile = file);
  }

  void _replaceImage() {
    // Keep simple: open gallery picker for replace action.
    _pickFromGallery();
  }

  void _removeImage() {
    setState(() => _pickedFile = null);
  }

  void _continue() {
    if (_pickedFile == null) return;
    Navigator.of(context).pushNamed(
      AppRoutes.faceSearchScanProgressPlaceholder,
      arguments: _pickedFile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _pickedFile != null;

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Face Search Upload',
        showBack: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(AppSpacing.lg),
                children: [
                  _buildPreviewSection(hasImage),
                  SizedBox(height: AppSpacing.lg),
                  _buildActionsSection(hasImage),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: hasImage ? _continue : null,
                  icon: Icon(Icons.north_east_rounded),
                  label: Text('Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewSection(bool hasImage) {
    if (!hasImage) {
      return const EmptyStateCard(
        icon: Icons.add_a_photo_outlined,
        message: 'Upload a selfie photo to start searching.',
      );
    }

    return Container(
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.check_rounded,
                    size: 18, color: AppColors.primary),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Selfie selected',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.file(
                File(_pickedFile!.path),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsSection(bool hasImage) {
    if (!hasImage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _pickFromGallery,
            icon: Icon(Icons.file_upload_outlined),
            label: Text('Upload from Gallery'),
          ),
          SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: _captureFromCamera,
            icon: Icon(Icons.camera_alt_rounded),
            label: Text('Capture from Camera'),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.borderColor),
            ),
          ),
          SizedBox(height: AppSpacing.lg),
          Text(
            'Tip: Use a clear selfie with good lighting for best results.',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _replaceImage,
          icon: Icon(Icons.swap_horiz_rounded),
          label: Text('Replace image'),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.borderColor),
          ),
        ),
        SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: _removeImage,
          icon: Icon(Icons.delete_outline_rounded),
          label: Text('Remove'),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.borderColor),
          ),
        ),
      ],
    );
  }
}
