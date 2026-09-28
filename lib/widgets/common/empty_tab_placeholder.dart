import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// Shared "coming soon" body for bottom-nav tabs that don't have real
/// content yet (Gallery, Alerts) — keeps every dummy tab visually
/// consistent instead of each screen inventing its own empty state.
class EmptyTabPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyTabPlaceholder(
      {super.key,
      required this.icon,
      required this.title,
      required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: AppColors.heroGradient,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.28),
                      blurRadius: 30,
                      offset: const Offset(0, 14)),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 42),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: context.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
