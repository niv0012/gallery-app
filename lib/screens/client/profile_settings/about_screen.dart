import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/app_info_provider.dart';
import '../../../widgets/common/custom_app_bar.dart';
import '../../../core/theme/theme_context.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App version is read live from the platform (package_info_plus)
    // instead of a hardcoded constant, so it always matches the
    // installed build.
    final versionAsync = ref.watch(appVersionLabelProvider);
    final version = versionAsync.when(
      data: (value) => value,
      loading: () => '…',
      error: (_, __) => '',
    );

    return Scaffold(
      appBar: const CustomAppBar(title: 'About', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.lg),
          children: [
            Container(
              padding: EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkSurface
                    : Colors.white,
                border: Border.all(color: context.borderColor),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: AppColors.primary),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('App Version',
                            style: Theme.of(context).textTheme.titleLarge),
                        SizedBox(height: 4),
                        Text(version,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: AppSpacing.lg),
            _SectionTile(
              icon: Icons.description_outlined,
              title: 'Terms & Conditions',
              subtitle: 'View terms of service',
              onTap: () =>
                  Navigator.of(context).pushNamed(AppRoutes.termsConditions),
            ),
            SizedBox(height: AppSpacing.md),
            _SectionTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              subtitle: 'View privacy policy',
              onTap: () =>
                  Navigator.of(context).pushNamed(AppRoutes.privacyPolicy),
            ),
            SizedBox(height: AppSpacing.md),
            _SectionTile(
              icon: Icons.support_agent_outlined,
              title: 'Contact Support',
              subtitle: 'Get help and view FAQs',
              onTap: () =>
                  Navigator.of(context).pushNamed(AppRoutes.helpSupport),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _SectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.darkSurface
              : Colors.white,
          border: Border.all(color: context.borderColor),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(color: context.borderColor),
              ),
              child: Icon(icon, color: AppColors.primary),
            ),
            SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  SizedBox(height: 4),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle)),
          ],
        ),
      ),
    );
  }
}
