import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_context.dart';

/// Shared visual layout for every onboarding page: a large gradient hero
/// icon tile, headline and supporting copy. Kept in one place so Pages
/// 1–3 stay pixel-identical in style while each only supplies its own
/// icon/title/description — matches the original inline `_PageContent`
/// this replaces.
class OnboardingPageContent extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const OnboardingPageContent({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Shrink the hero icon tile on short screens (small phones, or
        // extra chrome eating into the available height) instead of
        // letting it stay rigidly fixed-size and pushing the text past
        // the bottom of the Expanded PageView slot.
        final iconSize =
            constraints.maxHeight < 420 ? constraints.maxHeight * 0.32 : 190.0;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      gradient: AppColors.heroGradient,
                      borderRadius: BorderRadius.circular(48),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.3),
                          blurRadius: 44,
                          offset: const Offset(0, 20),
                        ),
                      ],
                    ),
                    child:
                        Icon(icon, color: Colors.white, size: iconSize * 0.44),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: context.textMuted),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
