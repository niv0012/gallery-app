import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// App-bar button that lets the user pick how many columns a media grid
/// shows. `columns == 1` means a list layout.
///
/// Shared by every grid screen (trash, albums, client galleries…) so the
/// control looks and behaves the same everywhere.
class GridColumnsButton extends StatelessWidget {
  const GridColumnsButton({
    super.key,
    required this.columns,
    required this.onChanged,
    this.options = const [1, 2, 3, 4],
  });

  final int columns;
  final ValueChanged<int> onChanged;
  final List<int> options;

  static IconData iconFor(int c) {
    if (c <= 1) return Icons.view_list_rounded;
    if (c == 2) return Icons.grid_view_rounded;
    if (c == 3) return Icons.apps_rounded;
    return Icons.view_comfy_rounded;
  }

  static String labelFor(int c) => c <= 1 ? 'List' : '$c columns';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Grid layout',
      icon: Icon(iconFor(columns), color: context.textPrimary),
      color: context.surfaceColor,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final c in options)
          PopupMenuItem<int>(
            value: c,
            child: Row(
              children: [
                Icon(iconFor(c),
                    size: 20,
                    color: c == columns ? AppColors.primary : context.textMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    labelFor(c),
                    style: TextStyle(
                      color: c == columns
                          ? AppColors.primary
                          : context.textPrimary,
                      fontWeight:
                          c == columns ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (c == columns)
                  const Icon(Icons.check_rounded,
                      size: 18, color: AppColors.primary),
              ],
            ),
          ),
      ],
    );
  }
}
