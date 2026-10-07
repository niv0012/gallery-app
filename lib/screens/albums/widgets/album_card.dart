import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/album_model.dart';
import 'album_cover_placeholder.dart';

class AlbumCard extends ConsumerWidget {
  const AlbumCard({
    super.key,
    required this.album,
    required this.onToggleFavorite,
    this.onTap,
    this.onEdit,
    this.onMove,
    this.onDelete,
    this.compact = false,
  });

  final AlbumModel album;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photoCount = album.photoCount;
    final videoCount = album.videoCount;
    final coverUrl = album.coverThumbnailUrl;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.darkSurface
                : Colors.white.withValues(alpha: 0.90),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
                color: isDark ? AppColors.darkBorder : AppColors.border),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 10),
                    ),
                  ],
          ),
          child: compact
              ? _buildCompactCard(
                  isDark: isDark,
                  coverUrl: coverUrl,
                  photoCount: photoCount,
                  videoCount: videoCount,
                )
              : _buildGridCard(
                  isDark: isDark,
                  coverUrl: coverUrl,
                  photoCount: photoCount,
                  videoCount: videoCount,
                ),
        ),
      ),
    );
  }

  Widget _buildCompactCard(
      {required bool isDark,
      String? coverUrl,
      required int photoCount,
      required int videoCount}) {
    final titleColor = isDark ? AppColors.textOnDark : AppColors.text;
    final subtitleColor =
        isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    return Padding(
      padding: EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: SizedBox(
              width: 90,
              height: 90,
              child: coverUrl != null
                  ? Image.network(
                      coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          AlbumCoverPlaceholder(gradient: album.gradient),
                    )
                  : AlbumCoverPlaceholder(
                      gradient: album.gradient,
                    ),
            ),
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '$photoCount Photos • $videoCount Videos',
                  style: TextStyle(
                    fontSize: 12,
                    color: subtitleColor,
                  ),
                ),

                SizedBox(height: 6),
                _BottomRow(
                  isDark: isDark,
                  isFavorite: album.isFavorite,
                  onToggleFavorite: onToggleFavorite,
                  onEdit: onEdit,
                  onMove: onMove,
                  onDelete: onDelete,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCard(
      {required bool isDark,
      String? coverUrl,
      required int photoCount,
      required int videoCount}) {
    return LayoutBuilder(builder: (context, constraints) {
      final isSmall = constraints.maxWidth < 120;
      
      return Stack(
        fit: StackFit.expand,
        children: [
          // Full background image
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: coverUrl != null
                ? Image.network(
                    coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        AlbumCoverPlaceholder(gradient: album.gradient),
                  )
                : AlbumCoverPlaceholder(
                    gradient: album.gradient,
                  ),
          ),
          // Gradient overlay for top button readability
          if (!isSmall)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.35),
                      Colors.transparent,
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.4],
                  ),
                ),
              ),
            ),
          // Frosted Glass Bottom Panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(AppRadius.lg)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: EdgeInsets.all(isSmall ? 8 : AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    border: Border(
                      top: BorderSide(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: isSmall ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isSmall ? 12 : 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.2,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (!isSmall) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$photoCount photos • $videoCount videos',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Floating action menu at top right
          if (!isSmall)
            Positioned(
              top: 8,
              left: 8,
              right: 4,
              child: _BottomRow(
                isDark: true, // Forcing dark mode ensures white icons
                isFavorite: album.isFavorite,
                onToggleFavorite: onToggleFavorite,
                onEdit: onEdit,
                onMove: onMove,
                onDelete: onDelete,
                isOverlay: true,
              ),
            ),
          // Simple heart for small cards if favorited
          if (isSmall && album.isFavorite)
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.favorite_rounded, color: AppColors.accent, size: 14),
            ),
        ],
      );
    });
  }
}

enum _AlbumMenuAction { edit, move, delete }

class _BottomRow extends StatelessWidget {
  const _BottomRow({
    required this.isDark,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.onEdit,
    this.onMove,
    this.onDelete,
    this.isOverlay = false,
  });

  final bool isDark;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onEdit;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;
  final bool isOverlay;

  @override
  Widget build(BuildContext context) {
    final hasMenu = onEdit != null || onMove != null || onDelete != null;
    final iconColor = isOverlay ? Colors.white : (isDark ? AppColors.subtitleOnDark : AppColors.subtitle);

    return Row(
      children: [
        IconButton(
          onPressed: onToggleFavorite,
          padding: EdgeInsets.zero,
          splashRadius: 18,
          constraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          icon: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            size: 20,
            color: isFavorite ? AppColors.accent : iconColor,
          ),
        ),
        const Spacer(),
        if (hasMenu)
          PopupMenuButton<_AlbumMenuAction>(
            padding: EdgeInsets.zero,
            splashRadius: 18,
            constraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
            tooltip: 'More actions',
            icon: Icon(
              Icons.more_vert_rounded,
              size: 20,
              color: iconColor,
            ),
            onSelected: (action) {
              switch (action) {
                case _AlbumMenuAction.edit:
                  onEdit?.call();
                  break;
                case _AlbumMenuAction.move:
                  onMove?.call();
                  break;
                case _AlbumMenuAction.delete:
                  onDelete?.call();
                  break;
              }
            },
            itemBuilder: (_) => [
              if (onEdit != null)
                const PopupMenuItem(
                  value: _AlbumMenuAction.edit,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Edit'),
                  ),
                ),
              if (onMove != null)
                const PopupMenuItem(
                  value: _AlbumMenuAction.move,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.drive_file_move_rounded),
                    title: Text('Move to folder'),
                  ),
                ),
              if (onDelete != null)
                const PopupMenuItem(
                  value: _AlbumMenuAction.delete,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        Icon(Icons.delete_outline_rounded, color: Colors.red),
                    title: Text('Delete', style: TextStyle(color: Colors.red)),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
