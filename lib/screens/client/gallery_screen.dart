import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/album_model.dart';
import '../../providers/client_gallery_provider.dart';
import '../../providers/connected_albums_provider.dart';
import '../../repositories/client_gallery_repository.dart';
import '../../widgets/client/home_sections.dart' show GalleryGrid;
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../../widgets/common/loading_widget.dart';
import 'main_nav_screen.dart';
import '../../widgets/common/anchored_dropdown_field.dart';
import '../../core/theme/theme_context.dart';

/// Client-facing subset of `AlbumsListScreen`'s `AlbumSortOption` — same
/// Recent/Name axes, plus `mostMedia` standing in for that screen's
/// separate photo-count/folder-count options (folders aren't a
/// client-facing concept here, so photo+video counts are combined).
enum _GallerySortOption { recent, name, mostMedia }

/// Gallery tab body — lives inside [MainNavScreen].
///
/// Was previously `MediaGridScreen(showBack: false)`, the studio-owner's
/// *own* media grid (backed by `/media`, `/albums`, `/folders` — all
/// gated by `get_current_studio_user` on the backend). A client account
/// always has `role == client`, so that call 403'd with "Only studio
/// accounts can manage a gallery" the instant this tab opened.
///
/// A client has no gallery of their own to manage — what they have is
/// read access to albums shared across every studio they're connected
/// to. This tab renders that as a grid (mirroring how
/// [SharedStudiosScreen] renders the same data as a flat list) with a
/// studio-chip row above it to scope the grid down to one studio at a
/// time.
///
/// Step 21.1 got the tab onto a grid shell. Step 21.2 wired it to
/// [connectedAlbumsProvider]. Step 21.3 added the studio-chip row. Step
/// 21.4 added the search field. Step 21.5 added the sort dropdown. Step
/// 21.6 added the "Liked" filter chip. Step 21.10 (this version) swaps
/// that chip's client-side filtering for the server-side `liked_only`
/// param `fetchConnectedAlbums` now supports (Task 21.9) — search and
/// sort stay client-side since the backend has no equivalent for those.
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: CustomAppBar(
        showBack: false,
        title: l10n.gallery,
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu_rounded),
            onPressed: () => context
                .findAncestorStateOfType<MainNavScreenState>()
                ?.openDrawer(),
          ),
        ),
      ),
      body: const SafeArea(child: _ClientGalleryGridView()),
    );
  }
}

/// The grid + studio-chip body for the bottom-nav Gallery tab.
///
/// Data sources are deliberately split, mirroring what each provider is
/// actually good at:
/// - The grid itself is [connectedAlbumsProvider]'s `fetchConnectedAlbums()`
///   with no `studioId` — every album across every connected studio in one
///   call — filtered client-side to the selected chip so switching studios
///   doesn't re-hit the network.
/// - The chip row is [clientGalleryProvider]'s `studios` list (the same
///   `SharedStudioModel`s [SharedStudioCard] renders on
///   [SharedStudiosScreen]) — "studios with an active share" — so the
///   chips only ever show studios actually worth filtering by.
class _ClientGalleryGridView extends ConsumerStatefulWidget {
  const _ClientGalleryGridView();

  @override
  ConsumerState<_ClientGalleryGridView> createState() =>
      _ClientGalleryGridViewState();
}

class _ClientGalleryGridViewState
    extends ConsumerState<_ClientGalleryGridView> {
  /// null = "All" chip selected (no studio scoping).
  String? _selectedStudioId;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _GallerySortOption _sortOption = _GallerySortOption.recent;

  bool _likedOnly = false;
  List<AlbumModel>? _likedAlbums;
  bool _isLoadingLikedAlbums = false;
  String? _likedAlbumsError;

  @override
  void initState() {
    super.initState();
    // connectedAlbumsProvider loads itself on first creation; only the
    // share-based studio list (for the chip row) needs an explicit kick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(clientGalleryProvider.notifier).loadStudios();
    });
  }

  /// Server-side liked-albums fetch (Task 21.10) — combines the "Liked"
  /// chip with whatever studio is currently selected in one request via
  /// `fetchConnectedAlbums(studioId: ..., likedOnly: true)`, rather than
  /// fetching every liked *media item* and deriving album ids
  /// client-side the way Task 21.6 did.
  Future<void> _fetchLikedAlbums() async {
    setState(() {
      _isLoadingLikedAlbums = true;
      _likedAlbumsError = null;
    });
    try {
      final repo = ref.read(clientGalleryRepositoryProvider);
      final albums = await repo.fetchConnectedAlbums(
        studioId: _selectedStudioId,
        likedOnly: true,
      );
      if (!mounted) return;
      setState(() {
        _likedAlbums = albums;
        _isLoadingLikedAlbums = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _likedAlbumsError = e.toString();
        _isLoadingLikedAlbums = false;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([
      ref.read(connectedAlbumsProvider.notifier).refresh(),
      ref.read(clientGalleryProvider.notifier).loadStudios(),
      if (_likedOnly) _fetchLikedAlbums(),
    ]);
  }

  void _onSelectStudio(String? studioId) {
    // Selecting a studio no longer connected/shared (stale chip mid-refresh)
    // just falls back to an empty filtered grid — no crash, no special-case.
    setState(() => _selectedStudioId = studioId);
    if (_likedOnly) _fetchLikedAlbums();
  }

  void _onToggleLiked(bool value) {
    setState(() => _likedOnly = value);
    if (value) _fetchLikedAlbums();
  }

  @override
  Widget build(BuildContext context) {
    final connectedState = ref.watch(connectedAlbumsProvider);
    final studios = ref.watch(clientGalleryProvider).studios;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: _buildBody(connectedState, studios),
    );
  }

  Widget _buildBody(
      ConnectedAlbumsState connectedState, List<SharedStudioModel> studios) {
    final hasLoadedAlbums = connectedState.albums.isNotEmpty;

    if (connectedState.isLoading && !hasLoadedAlbums) {
      return _scrollable(
        Center(
            child: LoadingWidget(message: 'Loading shared galleries…')),
      );
    }

    if (connectedState.error != null && !hasLoadedAlbums) {
      return _scrollable(
        Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: InlineErrorBanner(message: connectedState.error!),
          ),
        ),
      );
    }

    if (connectedState.albums.isEmpty) {
      return _scrollable(
        Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                EmptyStateCard(
                  icon: Icons.ios_share_rounded,
                  message: 'No Shared Galleries Yet',
                ),
                SizedBox(height: AppSpacing.md),
                Text(
                  'Studios you connect with will share galleries here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // When "Liked" is active, the base list comes from a dedicated
    // server-filtered fetch (studio + liked_only both applied in SQL —
    // see _fetchLikedAlbums) instead of client-side filtering the
    // shared connectedAlbumsProvider list, which Home also reads from
    // and shouldn't have narrowed out from under it.
    List<AlbumModel> baseAlbums;
    if (_likedOnly) {
      if (_isLoadingLikedAlbums && _likedAlbums == null) {
        return _scrollable(
          Center(
              child: LoadingWidget(message: 'Loading liked galleries…')),
        );
      }
      if (_likedAlbumsError != null && _likedAlbums == null) {
        return _scrollable(
          Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: InlineErrorBanner(message: _likedAlbumsError!),
            ),
          ),
        );
      }
      baseAlbums = _likedAlbums ?? const [];
    } else {
      baseAlbums = _selectedStudioId == null
          ? connectedState.albums
          : connectedState.albums
              .where((album) => album.studioId == _selectedStudioId)
              .toList(growable: false);
    }

    final String query = _searchQuery.trim().toLowerCase();
    final List<AlbumModel> searchFiltered = query.isEmpty
        ? baseAlbums
        : baseAlbums
            .where((album) => album.name.toLowerCase().contains(query))
            .toList(growable: false);

    final List<AlbumModel> filteredAlbums = _sorted(searchFiltered);

    return _scrollable(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: AppSpacing.md),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search galleries…',
                prefixIcon: Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
            ),
          ),
          SizedBox(height: AppSpacing.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: AnchoredDropdownField<_GallerySortOption>(
              value: _sortOption,
              items: const [
                DropdownMenuItem(
                  value: _GallerySortOption.recent,
                  child: Text('Recent'),
                ),
                DropdownMenuItem(
                  value: _GallerySortOption.name,
                  child: Text('Name'),
                ),
                DropdownMenuItem(
                  value: _GallerySortOption.mostMedia,
                  child: Text('Most media'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _sortOption = v);
              },
              decoration: const InputDecoration(labelText: 'Sort'),
            ),
          ),
          if (studios.isNotEmpty) ...[
            SizedBox(height: AppSpacing.md),
            _StudioFilterChips(
              studios: studios,
              selectedStudioId: _selectedStudioId,
              onSelect: _onSelectStudio,
            ),
          ],
          SizedBox(height: AppSpacing.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: Text('Liked'),
                avatar: Icon(Icons.favorite_rounded, size: 16),
                selected: _likedOnly,
                onSelected: _onToggleLiked,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: filteredAlbums.isEmpty
                ? EmptyStateCard(
                    icon: Icons.photo_library_outlined,
                    message: query.isNotEmpty
                        ? 'No galleries match "${_searchController.text}".'
                        : _likedOnly
                            ? 'No liked galleries yet.'
                            : 'No galleries shared from this studio yet.',
                  )
                : GalleryGrid(
                    albums: filteredAlbums, maxItems: filteredAlbums.length),
          ),
        ],
      ),
    );
  }

  List<AlbumModel> _sorted(List<AlbumModel> albums) {
    final sorted = [...albums];
    switch (_sortOption) {
      case _GallerySortOption.recent:
        sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        break;
      case _GallerySortOption.name:
        sorted.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case _GallerySortOption.mostMedia:
        sorted.sort((a, b) => (b.photoCount + b.videoCount)
            .compareTo(a.photoCount + a.videoCount));
        break;
    }
    return sorted;
  }

  Widget _scrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Studio-chip row — compact scope selector for the grid above. Reuses
// [SharedStudioModel] (the same data [SharedStudioCard] renders) but as
// small pill chips instead of full-width dark cards, since here it's a
// filter control rather than a navigation list.
// ─────────────────────────────────────────────────────────────────────────────

class _StudioFilterChips extends StatelessWidget {
  final List<SharedStudioModel> studios;
  final String? selectedStudioId;
  final ValueChanged<String?> onSelect;

  const _StudioFilterChips({
    required this.studios,
    required this.selectedStudioId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: studios.length + 1,
        separatorBuilder: (_, __) => SizedBox(width: 8),
        itemBuilder: (_, index) {
          if (index == 0) {
            return _StudioChip(
              label: 'All',
              selected: selectedStudioId == null,
              onTap: () => onSelect(null),
            );
          }
          final studio = studios[index - 1];
          return _StudioChip(
            label: studio.name,
            selected: selectedStudioId == studio.id,
            onTap: () => onSelect(studio.id),
          );
        },
      ),
    );
  }
}

class _StudioChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StudioChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : context.surfaceColor,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? AppColors.primary : context.borderColor,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
            ),
          ),
        ),
      ),
    );
  }
}
