import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/media_model.dart';
import '../../providers/client_gallery_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../media/image_viewer_screen.dart';
import '../media/video_player_screen.dart';
import '../../core/theme/theme_context.dart';
import '../../widgets/common/grid_columns_button.dart';
import '../../widgets/media/media_thumb.dart';

/// Client-facing "Favorites" destination.
///
/// The old client Home "Favorites" quick action pushed
/// `AppRoutes.mediaFavorites` → `MediaGridScreen(favoritesOnly: true)`,
/// which reads `GET /media` — a studio-only route
/// (`get_current_studio_user`) that 403s for a client account.
///
/// Now backed by `GET /media/liked-by-me` (`ClientGalleryRepository
/// .fetchLikedMedia`) — likes (Task 23) are the one favorite-like signal
/// a client account can both set (via the heart button in the image/video
/// viewer) and see, so this shows individual liked photos/videos across
/// every studio the client is connected to or shares an album with,
/// most-recently-liked first.
class ClientSavedGalleriesScreen extends ConsumerStatefulWidget {
  const ClientSavedGalleriesScreen({super.key});

  @override
  ConsumerState<ClientSavedGalleriesScreen> createState() =>
      _ClientSavedGalleriesScreenState();
}

class _ClientSavedGalleriesScreenState
    extends ConsumerState<ClientSavedGalleriesScreen> {
  List<MediaModel> _media = [];
  bool _isLoading = true;

  /// Grid density chosen from the app-bar picker.
  int _columns = 3;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final repo = ref.read(clientGalleryRepositoryProvider);
      final media = await repo.fetchLikedMedia();
      if (mounted) {
        setState(() {
          _media = media;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _openMedia(int index) {
    final media = _media[index];
    final allIds = _media.map((m) => m.id).toList();

    if (media.type == MediaType.video) {
      Navigator.of(context).pushNamed(
        AppRoutes.videoPlayer,
        arguments: VideoPlayerArgs(
          mediaId: media.id,
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: _media,
          readOnly: true,
        ),
      );
    } else {
      Navigator.of(context).pushNamed(
        AppRoutes.imageViewer,
        arguments: ImageViewerArgs(
          mediaIds: allIds,
          initialIndex: index,
          mediaItems: _media,
          readOnly: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: 'Favorites',
        actions: [
          GridColumnsButton(
            columns: _columns,
            options: const [2, 3, 4, 6],
            onChanged: (c) => setState(() => _columns = c),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _load,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _media.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _media.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.7,
          alignment: Alignment.center,
          padding: EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InlineErrorBanner(message: _error!),
              SizedBox(height: AppSpacing.md),
              ElevatedButton.icon(
                onPressed: _load,
                icon: Icon(Icons.refresh_rounded),
                label: Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_media.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.7,
          alignment: Alignment.center,
          padding: EdgeInsets.all(AppSpacing.xl),
          child: const EmptyStateCard(
            icon: Icons.favorite_border_rounded,
            message:
                'No liked photos or videos yet. Tap the heart on any photo '
                "in a studio's shared gallery to save it here.",
          ),
        ),
      );
    }

    return GridView.builder(
      physics:
          const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.all(AppSpacing.md),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 1.0,
      ),
      itemCount: _media.length,
      itemBuilder: (context, index) {
        final media = _media[index];
        return GestureDetector(
          onTap: () => _openMedia(index),
          child: Hero(
            tag: 'liked_media_${media.id}',
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: context.borderColor, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MediaThumb(
                      media: media, cacheWidth: _columns <= 2 ? 720 : 480),
                  if (media.type == MediaType.video)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Icon(
                      Icons.favorite_rounded,
                      color: AppColors.accent,
                      size: 16,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
