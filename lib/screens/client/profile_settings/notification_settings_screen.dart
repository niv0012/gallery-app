import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/auth_providers.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/common/custom_app_bar.dart';
import '../../../core/theme/theme_context.dart';

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUser = ref.watch(authProvider).valueOrNull;
    final settings = ref.watch(settingsProvider);

    final pushEnabled = authUser?.pushNotificationsEnabled ?? true;
    final emailEnabled =
        authUser?.emailNotificationsEnabled ?? settings.emailNotifications;

    return Scaffold(
      appBar:
          const CustomAppBar(title: 'Notification Settings', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.lg),
          children: [
            _ToggleTile(
              icon: Icons.notifications_active_rounded,
              title: 'Push Notifications',
              value: pushEnabled,
              onChanged: (v) async {
                await ref
                    .read(authProvider.notifier)
                    .updatePermissions(pushNotificationsEnabled: v);
              },
            ),
            SizedBox(height: AppSpacing.md),
            _ToggleTile(
              icon: Icons.email_outlined,
              title: 'Email Notifications',
              value: emailEnabled,
              onChanged: (v) {
                ref
                    .read(settingsProvider.notifier)
                    .updateSettings(settings.copyWith(emailNotifications: v));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
