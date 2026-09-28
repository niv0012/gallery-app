import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';

import '../../core/theme/app_theme.dart';
import '../../core/routes/app_routes.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';

/// UI for starting a face search: pick/take a selfie, then the buttons
/// route to Upload -> Scan Progress -> Results, backed by
/// [faceSearchProvider] for the real matching call.
class FaceSearchLandingScreen extends StatelessWidget {
  const FaceSearchLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
          children: [
            _buildIllustrationCard(context),
            SizedBox(height: AppSpacing.lg),
            _buildInfoCard(context),
            SizedBox(height: AppSpacing.lg),
            _buildUploadButtons(context),
          ],
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

  Widget _buildInfoCard(BuildContext context) {
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
                  'We will securely analyze your selfie and show matching photos across all your shared galleries using server-side AI face matching.',
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
              Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload);
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
              Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload);
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
