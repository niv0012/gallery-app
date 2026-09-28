import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// Floating top bar for the Studio Admin Dashboard — a gradient initials
/// avatar, a two-line "Good Morning / Studio Name" greeting, and glass
/// notification + search actions. Deliberately not a Material [AppBar]:
/// it scrolls in with the rest of the page like a Canva/Dropbox header.
class AdminTopBar extends StatelessWidget {
  final String name;
  final String studioName;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onSearchTap;
  final VoidCallback? onAvatarTap;
  final bool hasUnread;

  const AdminTopBar({
    super.key,
    required this.name,
    required this.studioName,
    this.onNotificationTap,
    this.onSearchTap,
    this.onAvatarTap,
    this.hasUnread = true,
  });

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: onAvatarTap,
          child: Container(
            width: 54,
            height: 54,
            padding: const EdgeInsets.all(2.4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.heroGradient,
              boxShadow: AppShadows.soft(AppColors.primary,
                  opacity: 0.30, blur: 20, y: 8),
            ),
            child: Container(
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Colors.white),
              padding: const EdgeInsets.all(2),
              child: Container(
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, gradient: AppColors.heroGradient),
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'N',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_greeting, $name'.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.secondary,
                  letterSpacing: 1.1,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                studioName,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                  letterSpacing: -0.3,
                  height: 1.1,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _ActionButton(icon: Icons.search_rounded, onTap: onSearchTap),
        const SizedBox(width: 10),
        _ActionButton(
            icon: Icons.notifications_none_rounded,
            onTap: onNotificationTap,
            showDot: hasUnread),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool showDot;

  const _ActionButton({required this.icon, this.onTap, this.showDot = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: context.surfaceColor.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.borderColor),
          boxShadow:
              AppShadows.soft(AppColors.primary, opacity: 0.08, blur: 14, y: 5),
        ),
        child: Stack(
          children: [
            Center(child: Icon(icon, size: 21, color: context.textPrimary)),
            if (showDot)
              Positioned(
                top: 11,
                right: 11,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: AppColors.accent, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
