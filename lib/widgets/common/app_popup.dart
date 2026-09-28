import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../buttons/gradient_button.dart';
import '../../core/theme/theme_context.dart';

/// Themed modal popup used in place of the default (plain, full-width,
/// dark) Material [SnackBar] for auth-flow messages — e.g. the "you
/// haven't verified yet" prompt on `verification_pending_screen.dart`
/// and `email_verification_screen.dart`. Matches the app's rounded,
/// soft-lavender card language instead of Flutter's stock dark bar.
///
/// [isError] swaps the icon/accent to the red error palette; otherwise
/// it uses the signature purple/pink gradient for neutral or success
/// messages.
class AppPopup extends StatelessWidget {
  final String title;
  final String message;
  final bool isError;
  final String buttonLabel;

  const AppPopup({
    super.key,
    required this.title,
    required this.message,
    this.isError = false,
    this.buttonLabel = 'Got It',
  });

  /// Shows the popup and resolves once the user dismisses it.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String message,
    bool isError = false,
    String buttonLabel = 'Got It',
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => AppPopup(
        title: title,
        message: message,
        isError: isError,
        buttonLabel: buttonLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.lg),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 30,
                offset: const Offset(0, 12)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: isError
                    ? LinearGradient(colors: [
                        AppColors.error.withValues(alpha: 0.85),
                        AppColors.error
                      ])
                    : AppColors.buttonGradient,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.mark_email_unread_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: GradientButton(
                label: buttonLabel,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
