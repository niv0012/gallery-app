import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/search_data.dart';
import '../../core/theme/theme_context.dart';

/// Shared horizontal filter-chip row for Global Search — originally a
/// private widget inside [GlobalSearchScreen], pulled out here so the new
/// [SearchResultsScreen] can reuse the exact same chips/styling instead
/// of a second implementation drifting out of sync.
class SearchFilterChips extends StatelessWidget {
  final SearchResultType? selected;
  final ValueChanged<SearchResultType?> onSelected;

  const SearchFilterChips(
      {super.key, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final types = [null, ...SearchResultType.values];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: types.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final type = types[i];
          final isSelected = selected == type;
          final label = type?.label ?? 'All';
          return InkWell(
            onTap: () => onSelected(type),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: AnimatedContainer(
              duration: AppDurations.fast,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                gradient: isSelected ? AppColors.buttonGradient : null,
                color: isSelected ? null : context.surfaceColor,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(
                    color: isSelected ? Colors.transparent : context.borderColor),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : context.textMuted,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
