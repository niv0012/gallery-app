import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../common/anchored_dropdown_field.dart';
import '../../core/theme/theme_context.dart';

class AlbumsListControls extends StatelessWidget {
  const AlbumsListControls({
    super.key,
    required this.searchController,
    required this.isGrid,
    required this.onToggleGrid,
    required this.sortOption,
    required this.onSortOptionChanged,
    required this.filterFavoriteOnly,
    required this.onFilterFavoriteOnlyChanged,
    required this.folders,
    required this.selectedFolderId,
    required this.onSelectedFolderChanged,
    required this.onSearchSubmitted,
  });

  final TextEditingController searchController;

  final bool isGrid;
  final VoidCallback onToggleGrid;

  final dynamic sortOption; // AlbumSortOption
  final ValueChanged<dynamic> onSortOptionChanged;

  final bool filterFavoriteOnly;
  final ValueChanged<bool> onFilterFavoriteOnlyChanged;

  final List<dynamic> folders; // FolderModel
  final String? selectedFolderId;
  final ValueChanged<String?> onSelectedFolderChanged;

  final VoidCallback onSearchSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: searchController,
          onSubmitted: (_) => onSearchSubmitted(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      searchController.clear();
                      onSearchSubmitted();
                    },
                  )
                : null,
            hintText: 'Search albums…',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: AnchoredDropdownField<dynamic>(
                value: sortOption,
                decoration: const InputDecoration(
                  labelText: 'Sort',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Recent')),
                  DropdownMenuItem(value: 1, child: Text('Name')),
                  DropdownMenuItem(value: 2, child: Text('Photo count')),
                  DropdownMenuItem(value: 3, child: Text('Folder count')),
                ],
                onChanged: onSortOptionChanged,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            GlassIconButton(
              icon: isGrid ? Icons.grid_view_rounded : Icons.view_list_rounded,
              onTap: onToggleGrid,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: AnchoredDropdownField<String?>(
                value: selectedFolderId,
                decoration: const InputDecoration(
                  labelText: 'Folder',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All folders'),
                  ),
                  ...folders.map((f) {
                    final name = (f as dynamic).name as String;
                    final id = (f as dynamic).id as String;
                    return DropdownMenuItem<String?>(
                        value: id, child: Text(name));
                  }),
                ],
                onChanged: onSelectedFolderChanged,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilterChip(
              label: const Text('Favorites'),
              selected: filterFavoriteOnly,
              onSelected: onFilterFavoriteOnlyChanged,
              selectedColor: AppColors.primary.withValues(alpha: 0.12),
              checkmarkColor: AppColors.primary,
            ),
          ],
        ),
      ],
    );
  }
}

class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const GlassIconButton({super.key, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          shape: BoxShape.circle,
          border: Border.all(color: context.borderColor),
        ),
        child: Icon(icon, size: 20, color: context.textPrimary),
      ),
    );
  }
}
