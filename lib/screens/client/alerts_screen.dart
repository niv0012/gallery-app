import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/notification_alert.dart';
import '../../providers/alerts_provider.dart';
import '../../widgets/common/empty_tab_placeholder.dart';
import '../../core/theme/theme_context.dart';

/// Alerts tab body — reads real alert data from [alertsProvider] and
/// falls back to [EmptyTabPlaceholder] when there's nothing to show.
/// Lives inside [MainNavScreen].
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(alertsProvider);

    if (controller.isLoading && controller.items.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (controller.items.isEmpty) {
      return const EmptyTabPlaceholder(
        icon: Icons.notifications_rounded,
        title: 'No Alerts Yet',
        message:
            'You\'ll be notified here when there\'s new\nactivity on your account.',
      );
    }

    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView.separated(
        padding: EdgeInsets.all(AppSpacing.md),
        itemCount: controller.items.length,
        separatorBuilder: (_, __) => SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          final alert = controller.items[index];
          return _AlertTile(
            alert: alert,
            onTap: () => ref.read(alertsProvider).markAsRead(alert.id),
          );
        },
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert, required this.onTap});

  final NotificationAlert alert;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: alert.isRead
          ? (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurface : AppColors.surface)
          : AppColors.primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: alert.isRead ? Colors.transparent : AppColors.primary,
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alert.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: alert.isRead
                                ? FontWeight.w600
                                : FontWeight.w800,
                          ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      alert.message,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
