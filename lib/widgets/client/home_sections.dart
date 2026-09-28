import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screens/client/main_nav_screen.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../models/studio_model.dart';
import '../../models/notification_alert.dart';
import '../../models/download_history_model.dart';
import '../../models/gallery_collection_model.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/auth_providers.dart';
import '../../providers/connected_albums_provider.dart';
import '../../providers/home_gallery_view_provider.dart';
import '../../providers/studio_provider.dart';
import '../../providers/alerts_provider.dart';
import '../../providers/studio_client_connections_provider.dart';

import '../common/empty_state_card.dart';
import '../../screens/albums/album_details_screen.dart';
import '../../screens/client/client_saved_galleries_screen.dart';
import '../../screens/client/favorite_albums_screen.dart';
import '../../screens/client/shared_album_preview_screen.dart';
import '../../screens/client/shared_studios_screen.dart' show SharedStudioCard;
import '../../providers/client_gallery_provider.dart';
import '../../screens/client/scan_qr_screen.dart';
import '../../core/theme/theme_context.dart';

// ─── Section Header ─────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;

  /// Shows the shared carousel<->grid toggle button next to the title.
  /// Used by the four `connectedAlbumsProvider`-backed sections below.
  final bool showViewToggle;

  const SectionHeader({
    super.key,
    required this.title,
    this.onSeeAll,
    this.showViewToggle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showViewToggle) const _HomeViewModeToggle(),
              if (onSeeAll != null)
                InkWell(
                  onTap: onSeeAll,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'See all',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small icon button that flips [homeGalleryViewModeProvider] between
/// carousel and grid. Shared by every section that opts into
/// [SectionHeader.showViewToggle], so toggling once switches all of
/// them together.
class _HomeViewModeToggle extends ConsumerWidget {
  const _HomeViewModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(homeGalleryViewModeProvider);
    final isGrid = mode == HomeGalleryViewMode.grid;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => ref.read(homeGalleryViewModeProvider.notifier).toggle(),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            isGrid ? Icons.view_carousel_outlined : Icons.grid_view_rounded,
            size: 18,
            color: context.textMuted,
          ),
        ),
      ),
    );
  }
}

// ─── Loading Skeleton ───────────────────────────────────────────────────

class SectionLoadingSkeleton extends StatelessWidget {
  final double height;
  final double width;

  const SectionLoadingSkeleton({
    super.key,
    this.height = 150,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => Container(
          width: width,
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.borderColor),
          ),
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionLoadingLine extends StatelessWidget {
  const SectionLoadingLine({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
  }
}

// ─── Error State Card ───────────────────────────────────────────────────

class ErrorStateCard extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorStateCard({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 30, color: AppColors.error),
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Gallery Carousel Card ──────────────────────────────────────────────

class GalleryCard extends StatelessWidget {
  final AlbumModel album;

  const GalleryCard({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    final assetCount = album.photoCount + album.videoCount;
    final coverUrl = album.coverThumbnailUrl;
    return Container(
      width: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: album.gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: AppShadows.soft(
          album.gradient.last,
          opacity: 0.24,
          blur: 20,
          y: 10,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            final studioId = album.studioId;
            if (studioId != null) {
              // Cross-studio "connected" album (from `connectedAlbumsProvider`
              // / `ConnectedAlbumRead`) — the studio-owner `AlbumDetailsScreen`
              // expects `albumProvider`/`mediaProvider` data this client was
              // never going to have, so route to the client-safe read-only
              // preview instead, same as `GalleryGrid`'s `sharedStudioId` path.
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SharedAlbumPreviewScreen(
                    studioId: studioId,
                    album: album,
                  ),
                ),
              );
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AlbumDetailsScreen(albumId: album.id),
              ),
            );
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Real cover photo when the album has one — same source
              // (`cover_thumbnail_url` / `ConnectedAlbumRead`) already used
              // by `_GalleryGridTile` below. Falls back to the plain
              // gradient (already painted as this Container's background)
              // for empty albums or on a network image error.
              if (coverUrl != null)
                Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: coverUrl != null
                          ? [Colors.black12, Colors.black87]
                          : [Colors.black12, Colors.black54],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 14,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$assetCount Asset${assetCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
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

// ─── Gallery Carousel ───────────────────────────────────────────────────

class GalleryCarousel extends StatelessWidget {
  final List<AlbumModel> albums;

  const GalleryCarousel({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: albums.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) => GalleryCard(album: albums[index]),
      ),
    );
  }
}

// ─── Gallery Grid ───────────────────────────────────────────────────────

class GalleryGrid extends StatelessWidget {
  final List<AlbumModel> albums;
  final int maxItems;

  /// When non-null, this grid is showing another studio's curated
  /// Shared Gallery (`StudioSharedFoldersScreen`) rather than the
  /// client's own `albumProvider` collection — tiles then open the
  /// read-only [SharedAlbumPreviewScreen] instead of the studio-owner
  /// [AlbumDetailsScreen], since the latter needs `albumProvider`/
  /// `mediaProvider` data a client viewing a *different* studio's
  /// album was never going to have.
  final String? sharedStudioId;

  const GalleryGrid({
    super.key,
    required this.albums,
    this.maxItems = 4,
    this.sharedStudioId,
  });

  @override
  Widget build(BuildContext context) {
    final items = albums.take(maxItems).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _crossAxisCount(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.5,
          ),
          itemCount: items.length,
          itemBuilder: (_, index) => _GalleryGridTile(
            album: items[index],
            sharedStudioId: sharedStudioId,
          ),
        );
      },
    );
  }

  int _crossAxisCount(double width) {
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }
}

class _GalleryGridTile extends StatelessWidget {
  final AlbumModel album;
  final String? sharedStudioId;

  const _GalleryGridTile({required this.album, this.sharedStudioId});

  void _open(BuildContext context) {
    // Explicit grid-level sharedStudioId (studio_shared_folders_screen.dart's
    // single-studio drill-down) wins; otherwise fall back to the album's own
    // studioId, set when this tile came from `connectedAlbumsProvider`
    // (cross-studio "connected" view, e.g. Home's Saved Galleries).
    final studioId = sharedStudioId ?? album.studioId;
    if (studioId != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SharedAlbumPreviewScreen(
            studioId: studioId,
            album: album,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailsScreen(albumId: album.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = album.coverThumbnailUrl;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: coverUrl == null
                ? LinearGradient(
                    colors: album.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            boxShadow: AppShadows.soft(
              album.gradient.last,
              opacity: 0.2,
              blur: 14,
              y: 8,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (coverUrl != null)
                Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: album.gradient,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                ),
              if (coverUrl != null)
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black45],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              Align(
                alignment:
                    coverUrl == null ? Alignment.center : Alignment.bottomLeft,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign:
                        coverUrl == null ? TextAlign.center : TextAlign.left,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // Task 21.24: informational lock badge — a password-protected
              // public share link also exists for this album. Never implies
              // *this* client needs a password (their access is already
              // granted directly; see Task 21.23's audit).
              if (album.hasProtectedShareLink)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Tooltip(
                    message:
                        'A password-protected link also exists for this gallery',
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.lock_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Studio Card (Connected) ────────────────────────────────────────────

class ConnectedStudioCard extends StatelessWidget {
  final StudioModel studio;

  const ConnectedStudioCard({super.key, required this.studio});

  @override
  Widget build(BuildContext context) {
    final hasLogo = studio.logoUrl.isNotEmpty;

    return Container(
      width: 160,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
        boxShadow: AppShadows.subtle,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.of(context).pushNamed(
            AppRoutes.studioProfile,
            arguments: studio.id,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: hasLogo
                            ? null
                            : AppColors.primary.withValues(alpha: 0.1),
                        gradient: hasLogo ? null : AppColors.buttonGradient,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: hasLogo
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: studio.logoUrl.startsWith('http')
                                  ? Image.network(studio.logoUrl,
                                      fit: BoxFit.cover, width: 36, height: 36)
                                  : Image.file(File(studio.logoUrl),
                                      fit: BoxFit.cover, width: 36, height: 36),
                            )
                          : Text(
                              studio.name.isNotEmpty
                                  ? studio.name[0].toUpperCase()
                                  : 'S',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: AppColors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'Connected',
                            style: TextStyle(
                              color: AppColors.success,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  studio.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  studio.location.isNotEmpty ? studio.location : 'Studio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      'View Studio',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.primary,
                      size: 14,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Studio Carousel ────────────────────────────────────────────────────

class StudioCarousel extends StatelessWidget {
  final List<StudioModel> studios;

  const StudioCarousel({super.key, required this.studios});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: studios.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) => ConnectedStudioCard(studio: studios[index]),
      ),
    );
  }
}

// ─── Activity Tile ──────────────────────────────────────────────────────

class ActivityTile extends StatelessWidget {
  final NotificationAlert alert;

  const ActivityTile({super.key, required this.alert});

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      // Same fix as RecentActivitySection.onSeeAll and the Home header
      // bell icon: this pushed the Studio's NotificationsScreen, which
      // clients can't meaningfully use. Switch to the client's own
      // Alerts tab (index 2) instead.
      onTap: () =>
          context.findAncestorStateOfType<MainNavScreenState>()?.goToTab(2),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: AppColors.buttonGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.notifications_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          alert.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: alert.isRead
                                ? FontWeight.w600
                                : FontWeight.w800,
                            color: isDark ? AppColors.textOnDark : AppColors.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _timeAgo(alert.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    alert.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (!alert.isRead)
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 4),
                child: SizedBox(
                  width: 8,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Activity List ──────────────────────────────────────────────────────

class ActivityList extends StatelessWidget {
  final List<NotificationAlert> alerts;

  const ActivityList({super.key, required this.alerts});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.borderColor),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: alerts.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, thickness: 1, color: context.borderColor),
        itemBuilder: (_, index) => ActivityTile(alert: alerts[index]),
      ),
    );
  }
}

// ─── Downloads List ─────────────────────────────────────────────────────

class DownloadsList extends StatelessWidget {
  final List<DownloadHistoryModel> downloads;

  const DownloadsList({super.key, required this.downloads});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.borderColor),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: downloads.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, thickness: 1, color: context.borderColor),
        itemBuilder: (_, index) => _DownloadTile(download: downloads[index]),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadHistoryModel download;

  const _DownloadTile({required this.download});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: () => Navigator.of(context).pushNamed(AppRoutes.downloadHistory),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: AppColors.buttonGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.download_rounded,
                  color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    download.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.textOnDark : AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${download.downloadedAt.month}/${download.downloadedAt.day} ${download.downloadedAt.hour.toString().padLeft(2, '0')}:${download.downloadedAt.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle),
          ],
        ),
      ),
    );
  }
}

// ─── Collections Chips ──────────────────────────────────────────────────

class CollectionsChips extends StatelessWidget {
  final List<GalleryCollectionModel> collections;

  const CollectionsChips({super.key, required this.collections});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: collections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final c = collections[index];
          return Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.darkSurface
                : Colors.white,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => Navigator.of(context).pushNamed(
                AppRoutes.collectionsDetails,
                arguments: c.id,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: context.borderColor),
                ),
                child: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Quick Action Row ───────────────────────────────────────────────────

class _QuickAction {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  _QuickAction({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
    required this.onTap,
  });
}

class QuickActionRow extends StatelessWidget {
  const QuickActionRow({super.key});

  @override
  Widget build(BuildContext context) {
    final actions = <_QuickAction>[
      _QuickAction(
        icon: Icons.search_rounded,
        label: 'Discover Studios',
        bg: AppColors.primary.withValues(alpha: 0.12),
        fg: AppColors.primary,
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.discoverStudios),
      ),
      _QuickAction(
        icon: Icons.qr_code_scanner_rounded,
        label: 'Scan QR',
        bg: AppColors.accent.withValues(alpha: 0.12),
        fg: AppColors.accent,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ScanQrScreen()),
        ),
      ),
      _QuickAction(
        icon: Icons.photo_library_rounded,
        label: 'My Galleries',
        bg: AppColors.secondary.withValues(alpha: 0.12),
        fg: AppColors.secondary,
        onTap: () {
          context.findAncestorStateOfType<MainNavScreenState>()?.goToTab(1);
        },
      ),
      _QuickAction(
        icon: Icons.favorite_rounded,
        label: 'Favorites',
        bg: AppColors.gold.withValues(alpha: 0.18),
        fg: const Color(0xFF9A6B1E),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ClientSavedGalleriesScreen()),
        ),
      ),
    ];

    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, index) {
          final a = actions[index];
          return SizedBox(
            width: 64,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: a.onTap,
                child: Column(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: a.bg,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(a.icon, size: 22, color: a.fg),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Section Builders (used by HomeScreen) ─────────────────────────────

/// Builds the "Connected Studios" section.
///
/// Depends on [studioProvider] to resolve each connection's studio
/// details, but nothing else on the Home screen ever populates it —
/// only [DiscoverStudiosScreen] and [StudioProfileScreen] call
/// [StudioNotifier.ensureDirectoryLoaded]. Without the same call here,
/// a client who opens Home before ever visiting Discover Studios this
/// session sees an empty [studios] list, so even a real, accepted
/// connection fails the id lookup below and the section wrongly falls
/// back to the "not connected" empty state.
class ConnectedStudiosSection extends ConsumerStatefulWidget {
  const ConnectedStudiosSection({super.key});

  @override
  ConsumerState<ConnectedStudiosSection> createState() =>
      _ConnectedStudiosSectionState();
}

class _ConnectedStudiosSectionState
    extends ConsumerState<ConnectedStudiosSection> {
  @override
  void initState() {
    super.initState();
    // Only fetches if the directory hasn't already been loaded this
    // session — see StudioNotifier.ensureDirectoryLoaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(studioProvider.notifier).ensureDirectoryLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final clientId = ref.watch(authStateProvider).user?.id ?? '';
    final connections = ref.watch(connectionsProvider).valueOrNull ?? [];
    final studiosState = ref.watch(studioProvider);
    final studios = studiosState.studios;

    // "Connected" (accepted `StudioClientConnection`) and "shared with"
    // (active `AlbumClientShare`) are independent relationships — a
    // client can have one without the other. Checked here purely so
    // the empty-state copy below doesn't read as a flat "nothing here"
    // when the "Shared With You" section further down the page is
    // about to show something.
    final hasActiveShares = ref.watch(clientGalleryProvider).studios.isNotEmpty;

    final connectedConnections = connections
        .where((c) =>
            c.clientId == clientId && c.status == ConnectionStatus.connected)
        .toList();

    final connectedStudios = connectedConnections
        .map((conn) {
          try {
            return studios.firstWhere((s) => s.id == conn.studioId);
          } catch (_) {
            return null;
          }
        })
        .whereType<StudioModel>()
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
              title: connectedStudios.isNotEmpty
                  ? 'Connected Studios (${connectedStudios.length})'
                  : 'Connected Studios'),
        ),
        if (studiosState.isLoadingDirectory &&
            connectedConnections.isNotEmpty &&
            connectedStudios.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SectionLoadingLine(),
          )
        else if (connectedConnections.isEmpty || connectedStudios.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkSurface
                    : Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: context.borderColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 38,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    hasActiveShares
                        ? "Not connected with a studio yet"
                        : "No studio connected yet",
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    hasActiveShares
                        ? "A studio has shared galleries with you (see below), but you're not fully connected yet. Connect for full access to their gallery."
                        : "Discover studios, explore their work, and connect with a studio.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.textMuted,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context)
                          .pushNamed(AppRoutes.discoverStudios);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    child: const Text(
                      "Discover Studios",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          StudioCarousel(studios: connectedStudios),
      ],
    );
  }
}

/// Builds the "Continue Viewing" / "Recent Galleries" section.
class ContinueViewingSection extends ConsumerWidget {
  const ContinueViewingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedState = ref.watch(connectedAlbumsProvider);
    final recentGalleries = connectedState.recentAlbums();
    final isLoading = connectedState.isLoading && connectedState.albums.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Continue browsing',
            // AppRoutes.media pushes MediaGridScreen, backed by
            // mediaProvider -> GET /media, which is studio-only
            // (get_current_studio_user) and 403s for a client account —
            // same class of bug already fixed on RecentActivitySection's
            // "See All" below. The client-facing equivalent of "all
            // galleries" is just the Gallery bottom-nav tab itself.
            onSeeAll: () => context
                .findAncestorStateOfType<MainNavScreenState>()
                ?.goToTab(1),
            showViewToggle: true,
          ),
        ),
        if (isLoading)
          const SectionLoadingSkeleton()
        else if (recentGalleries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: EmptyStateCard(
              icon: Icons.photo_library_outlined,
              message: 'No recent galleries yet.',
            ),
          )
        else if (ref.watch(homeGalleryViewModeProvider) ==
            HomeGalleryViewMode.grid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: GalleryGrid(albums: recentGalleries),
          )
        else
          GalleryCarousel(albums: recentGalleries),
      ],
    );
  }
}

/// Builds the "Recently Viewed" section.
class RecentlyViewedSection extends ConsumerWidget {
  const RecentlyViewedSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedState = ref.watch(connectedAlbumsProvider);
    final isLoading = connectedState.isLoading && connectedState.albums.isEmpty;

    final recent = connectedState.recentAlbums();

    if (recent.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Recently Viewed',
            // See ContinueViewingSection above — AppRoutes.media 403s
            // for a client account; the Gallery tab is the real
            // client-facing "all galleries" destination.
            onSeeAll: () => context
                .findAncestorStateOfType<MainNavScreenState>()
                ?.goToTab(1),
            showViewToggle: true,
          ),
        ),
        if (isLoading)
          const SectionLoadingSkeleton()
        else if (ref.watch(homeGalleryViewModeProvider) ==
            HomeGalleryViewMode.grid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: GalleryGrid(albums: recent),
          )
        else
          GalleryCarousel(albums: recent),
      ],
    );
  }
}

/// Builds the "Trending" section (albums sorted by asset count).
class TrendingGalleriesSection extends ConsumerWidget {
  const TrendingGalleriesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedState = ref.watch(connectedAlbumsProvider);
    final isLoading = connectedState.isLoading && connectedState.albums.isEmpty;

    final items = connectedState.trendingAlbums();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Trending',
            // See ContinueViewingSection above — AppRoutes.media 403s
            // for a client account; the Gallery tab is the real
            // client-facing "all galleries" destination.
            onSeeAll: () => context
                .findAncestorStateOfType<MainNavScreenState>()
                ?.goToTab(1),
            showViewToggle: true,
          ),
        ),
        if (isLoading)
          const SectionLoadingSkeleton()
        else if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: EmptyStateCard(
              icon: Icons.trending_up_rounded,
              message: 'No trending galleries yet.',
            ),
          )
        else if (ref.watch(homeGalleryViewModeProvider) ==
            HomeGalleryViewMode.grid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: GalleryGrid(albums: items),
          )
        else
          GalleryCarousel(albums: items),
      ],
    );
  }
}

/// Builds the "Saved Galleries" (favorites) section.
class SavedGalleriesSection extends ConsumerWidget {
  const SavedGalleriesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedState = ref.watch(connectedAlbumsProvider);
    final isLoading = connectedState.isLoading && connectedState.albums.isEmpty;
    final favoriteGalleries = connectedState.favoriteAlbums;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Saved Galleries',
            onSeeAll: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FavoriteAlbumsScreen()),
            ),
          ),
        ),
        if (isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SectionLoadingLine(),
          )
        else if (favoriteGalleries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: EmptyStateCard(
              icon: Icons.bookmark_border_rounded,
              message: 'No saved galleries yet.',
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: GalleryGrid(albums: favoriteGalleries),
          ),
      ],
    );
  }
}

/// Builds the "Recent Activity" section from alerts.
class RecentActivitySection extends ConsumerWidget {
  const RecentActivitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsState = ref.watch(alertsProvider);
    final recentAlerts = alertsState.items.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Recent Activity',
            // AppRoutes.notifications points at the Studio's
            // NotificationsScreen (backed by adminDashboardProvider) —
            // pushing it from the Client Home tab showed the wrong data
            // entirely (studio notifications) or failed to load, since
            // clients don't have a studio dashboard. The client's own
            // notifications already live on the Alerts bottom-nav tab
            // (index 2 in MainNavScreen), so "See All" should just
            // switch to that tab instead of pushing an unrelated route.
            onSeeAll: () => context
                .findAncestorStateOfType<MainNavScreenState>()
                ?.goToTab(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: alertsState.isLoading && alertsState.items.isEmpty
              ? const SectionLoadingLine()
              : recentAlerts.isEmpty
                  ? const EmptyStateCard(
                      icon: Icons.notifications_none_rounded,
                      message: 'No recent activity.',
                    )
                  : ActivityList(alerts: recentAlerts),
        ),
      ],
    );
  }
}

/// Builds the "Upcoming Shared Galleries" placeholder section.
/// No provider exposes this data, so we display an empty state.
///
/// Renders the exact same [SharedStudioCard] class [SharedStudiosScreen]
/// uses (imported via `show` above, not a copy) — so Task 21.17's
/// GlassCard redesign of that card applies here automatically. Task
/// 21.18 confirmed this and needed no further change: both places
/// already rendered from one shared widget, not two cards that happened
/// to look alike.
class SharedGalleriesSection extends ConsumerWidget {
  const SharedGalleriesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(clientGalleryProvider);
    final studios = state.studios;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SectionHeader(
            title: 'Shared With You',
            onSeeAll: studios.isEmpty
                ? null
                : () =>
                    Navigator.of(context).pushNamed(AppRoutes.sharedStudios),
          ),
        ),
        if (state.isLoadingStudios && studios.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SectionLoadingLine(),
          )
        else if (studios.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: () =>
                  Navigator.of(context).pushNamed(AppRoutes.sharedStudios),
              child: const EmptyStateCard(
                icon: Icons.ios_share_rounded,
                message:
                    'No shared galleries yet. Your studio will share galleries with you here.',
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              children: studios
                  .take(3)
                  .map(
                    (studio) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: SharedStudioCard(studio: studio),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }
}
