import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_context.dart';

class RecentPhotosPlaceholder extends StatelessWidget {
  const RecentPhotosPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Photos',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.textOnDark
                    : AppColors.text)),
          ),
          SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _photoThumb(context),
              SizedBox(width: AppSpacing.sm),
              _photoThumb(context),
              SizedBox(width: AppSpacing.sm),
              _photoThumb(context),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            'Photo timeline will appear here in later phases.',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle)),
          ),
        ],
      ),
    );
  }

  Widget _photoThumb(BuildContext context) {
    return Expanded(
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            decoration: BoxDecoration(
              gradient: AppColors.softWash,
              border: Border.all(color: AppColors.border),
            ),
            child: Center(
              child: Icon(Icons.image_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle),
                  size: 28),
            ),
          ),
        ),
      ),
    );
  }
}
