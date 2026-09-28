import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/admin_dashboard_data.dart';
import '../../core/theme/theme_context.dart';

/// Single row in the Notifications section — a colored, type-specific
/// gradient icon badge (reminder / approval / gallery-viewed),
/// title, subtitle and a relative timestamp.
class NotificationTile extends StatelessWidget {
  final NotificationData data;
  final bool isLast;
  final VoidCallback? onTap;

  const NotificationTile(
      {super.key, required this.data, this.isLast = false, this.onTap});

  (IconData, List<Color>) get _style {
    switch (data.type) {
      case NotificationType.reminder:
        return (
          Icons.alarm_rounded,
          const [Color(0xFF7C5CFF), Color(0xFFA855F7)]
        );
      case NotificationType.approval:
        return (
          Icons.rate_review_rounded,
          const [Color(0xFFF59E0B), Color(0xFFEC4899)]
        );

      case NotificationType.gallery:
        return (
          Icons.visibility_rounded,
          const [Color(0xFFA855F7), Color(0xFFEC4899)]
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, gradient) = _style;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.only(
            bottom: isLast ? 0 : AppSpacing.md, top: 4, left: 4, right: 4),
        child: Opacity(
          opacity: data.isRead ? 0.55 : 1,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: gradient,
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, color: Colors.white, size: 18),
                  ),
                  if (!data.isRead)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data.title,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary)),
                    const SizedBox(height: 2),
                    Text(data.subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: context.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(data.time,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: context.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
