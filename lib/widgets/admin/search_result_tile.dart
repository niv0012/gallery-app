import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../models/search_data.dart';
import '../../core/theme/theme_context.dart';

/// Single row in Global Search results — same gradient icon-badge +
/// title/subtitle language as [NotificationTile] and [RecentClientTile],
/// with a small type-label pill on the right so mixed-type ("All")
/// result lists stay scannable.
class SearchResultTile extends StatelessWidget {
  final SearchResultItem data;
  final VoidCallback? onTap;

  const SearchResultTile({super.key, required this.data, this.onTap});

  @override
  Widget build(BuildContext context) {
    final gradient = data.type.gradient;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(data.type.icon, color: Colors.white, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(data.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: context.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: gradient.first.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(data.type.label,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: gradient.first)),
            ),
          ],
        ),
      ),
    );
  }
}
