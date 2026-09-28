import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_context.dart';

/// The action the user picked from [AddMediaBottomSheet].
enum AddMediaAction { photos, videos }

/// Modern bottom sheet shown from the Album Details FAB.
///
/// This widget only surfaces the choice — actually invoking
/// `image_picker` and writing to [mediaProvider] is left to the caller,
/// mirroring the existing folder-picker sheet pattern already used in
/// [AlbumDetailsScreen] (`_pickFolder`).
class AddMediaBottomSheet extends StatelessWidget {
  const AddMediaBottomSheet({super.key});

  static Future<AddMediaAction?> show(BuildContext context) {
    return showModalBottomSheet<AddMediaAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => const AddMediaBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Media',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            SizedBox(height: AppSpacing.md),
            _ActionTile(
              icon: Icons.add_photo_alternate_rounded,
              iconColor: AppColors.primary,
              label: 'Add Photos',
              subtitle: 'Choose one or more photos from your gallery',
              onTap: () => Navigator.of(context).pop(AddMediaAction.photos),
            ),
            SizedBox(height: AppSpacing.sm),
            _ActionTile(
              icon: Icons.video_camera_back_rounded,
              iconColor: AppColors.secondary,
              label: 'Add Videos',
              subtitle: 'Choose a video from your gallery',
              onTap: () => Navigator.of(context).pop(AddMediaAction.videos),
            ),
            SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  foregroundColor:
                      (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle),
                ),
                child: Text('Cancel',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, color: iconColor),
              ),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.textOnDark
                                  : AppColors.text)),
                    ),
                    SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ],
          ),
        ),
      ),
    );
  }
}
