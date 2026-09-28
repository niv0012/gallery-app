import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/studio_model.dart';
import '../../providers/studio_provider.dart';
import '../../widgets/cards/glass_card.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

class DiscoverStudiosScreen extends ConsumerStatefulWidget {
  const DiscoverStudiosScreen({super.key});

  @override
  ConsumerState<DiscoverStudiosScreen> createState() =>
      _DiscoverStudiosScreenState();
}

class _DiscoverStudiosScreenState extends ConsumerState<DiscoverStudiosScreen> {
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
    final provider = ref.watch(studioProvider);
    final studios = provider.filteredStudios;
    final categories = [
      'All',
      'Wedding',
      'Portrait',
      'Fashion',
      'Editorial',
      'Event',
      'Landscape',
      'Family'
    ];

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Discover Studios',
        showBack: true,
      ),
      body: ScreenBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              // 1. Search Bar
              Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
                child: TextField(
                  onChanged: (val) =>
                      ref.read(studioProvider).setSearchQuery(val),
                  style: TextStyle(color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text), fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search by studio, location, or tag...',
                    hintStyle: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle), fontSize: 14),
                    prefixIcon: Icon(Icons.search_rounded,
                        color: AppColors.primary),
                    suffixIcon: provider.searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear_rounded,
                                color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle)),
                            onPressed: () {
                              ref.read(studioProvider).setSearchQuery('');
                            },
                          )
                        : null,
                    fillColor: Theme.of(context).brightness == Brightness.dark
                        ? AppColors.darkSurface
                        : Colors.white.withValues(alpha: 0.8),
                    filled: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                          color: AppColors.primary, width: 1.6),
                    ),
                  ),
                ),
              ),

              // 2. Categories Horizontal Scroller
              SizedBox(
                height: 52,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: 8),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final cat = categories[index];
                    final isSelected = provider.selectedCategory == cat;
                    return Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          cat,
                          style: TextStyle(
                            color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.w500,
                            fontSize: 13,
                          ),
                        ),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            ref.read(studioProvider).setSelectedCategory(cat);
                          }
                        },
                        selectedColor: AppColors.primary,
                        backgroundColor:
                            Theme.of(context).brightness == Brightness.dark
                                ? AppColors.darkSurface
                                : Colors.white,
                        checkmarkColor: Colors.white,
                        showCheckmark: false,
                        padding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: isSelected
                                ? AppColors.primary
                                : context.borderColor,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              // 3. Studio List
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () =>
                      ref.read(studioProvider.notifier).loadDirectory(),
                  child: _buildBody(provider, studios),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(StudioNotifier provider, List<StudioModel> studios) {
    // Full-screen loading only applies before anything has ever loaded —
    // a pull-to-refresh while studios are already showing shouldn't
    // blank the list out from under the user.
    if (provider.isLoadingDirectory && provider.studios.isEmpty) {
      return _scrollableMessage(
        Center(
            child: LoadingWidget(message: 'Finding studios near you…')),
      );
    }

    if (provider.directoryError != null && provider.studios.isEmpty) {
      return _scrollableMessage(
        Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: InlineErrorBanner(
              message: provider.directoryError!,
              action: TextButton(
                onPressed: () =>
                    ref.read(studioProvider.notifier).loadDirectory(),
                child: Text('Retry'),
              ),
            ),
          ),
        ),
      );
    }

    if (studios.isEmpty) {
      return _scrollableMessage(_buildEmptyState());
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.md, 8, AppSpacing.md, AppSpacing.lg),
      physics:
          const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      itemCount: studios.length,
      itemBuilder: (context, index) {
        final studio = studios[index];
        return Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: StudioCard(studio: studio),
        );
      },
    );
  }

  /// Wraps a centered message in a scrollable so [RefreshIndicator]'s
  /// pull-to-refresh gesture still works on the loading/error/empty
  /// states, not just the populated list.
  Widget _scrollableMessage(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: context.borderColor.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.search_off_rounded,
              size: 48,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
            ),
          ),
          SizedBox(height: 16),
          Text(
            'No Studios Found',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Try adjusting your search filters or queries.',
            style: TextStyle(
              fontSize: 14,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
            ),
          ),
        ],
      ),
    );
  }
}

class StudioCard extends ConsumerWidget {
  final StudioModel studio;

  const StudioCard({super.key, required this.studio});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: 20,
      child: InkWell(
        onTap: () {
          Navigator.pushNamed(
            context,
            AppRoutes.studioProfile,
            arguments: studio.id,
          );
        },
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover Image + Logo Overlay
            SizedBox(
              height: 140,
              child: Stack(
                children: [
                  // Cover Image
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(20)),
                      child: Image.network(
                        studio.coverUrl,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            color: context.borderColor.withValues(alpha: 0.5),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: context.borderColor,
                          child: Icon(Icons.image_rounded,
                              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle)),
                        ),
                      ),
                    ),
                  ),
                  // Darken Overlay at top
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(20)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black45,
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Rating Badge in top right
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star_rounded,
                              color: AppColors.gold, size: 14),
                          SizedBox(width: 4),
                          Text(
                            studio.rating.toString(),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Favorite toggle in top left
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                      onTap: () => ref
                          .read(studioProvider.notifier)
                          .toggleFavorite(studio.id),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.45),
                        ),
                        child: Icon(
                          studio.isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: studio.isFavorite
                              ? AppColors.error
                              : Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  // Logo overlay floating bottom left
                  Positioned(
                    bottom: -16,
                    left: 16,
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.network(
                          studio.logoUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Icon(
                            Icons.business_rounded,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 24), // Offset for floating logo

            // Content Section
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name and Location
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          studio.name,
                          style: TextStyle(
                            color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.location_on_rounded,
                          color: AppColors.primary, size: 14),
                      SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          studio.location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),

                  // Categories tags
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: studio.categories.map((cat) {
                      return Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          cat,
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  SizedBox(height: 16),

                  // About description snippet
                  Text(
                    studio.about,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 16),

                  // Action Row: Connect Button & Details navigation
                  Row(
                    children: [
                      Expanded(
                        child: _ConnectButton(studio: studio),
                      ),
                      SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () {
                          Navigator.pushNamed(
                            context,
                            AppRoutes.studioProfile,
                            arguments: studio.id,
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: EdgeInsets.symmetric(
                              vertical: 14, horizontal: 16),
                        ),
                        child: Text(
                          'View Profile',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectButton extends ConsumerWidget {
  final StudioModel studio;

  const _ConnectButton({required this.studio});

  Future<void> _handleTap(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(studioProvider.notifier);

    switch (studio.connectionStatus) {
      case StudioConnectionStatus.notConnected:
        final success = await notifier.requestConnection(studio.id);
        if (!context.mounted) return;
        _showSnack(
          context,
          success
              ? 'Connection request sent to ${studio.name}!'
              : 'Could not send the request. Try again.',
          isError: !success,
        );
        break;

      case StudioConnectionStatus.pending:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Withdraw request?'),
            content: Text(
                'Your pending request to ${studio.name} will be withdrawn.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Withdraw'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        final success = await notifier.withdrawConnectionRequest(studio.id);
        if (!context.mounted) return;
        _showSnack(
          context,
          success
              ? 'Request to ${studio.name} withdrawn.'
              : 'Could not withdraw the request. Try again.',
          isError: !success,
        );
        break;

      case StudioConnectionStatus.connected:
        _showSnack(context, 'You\'re already connected with ${studio.name}.');
        break;
    }
  }

  void _showSnack(BuildContext context, String message,
      {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_rounded,
              color: Colors.white,
            ),
            SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: isError ? AppColors.error : AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = studio.connectionStatus;
    final isPendingCall = ref.watch(studioProvider
        .select((p) => p.pendingConnectionIds.contains(studio.id)));

    Color buttonColor;
    Color textColor;
    String label;
    IconData? icon;

    switch (status) {
      case StudioConnectionStatus.notConnected:
        buttonColor = AppColors.primary;
        textColor = Colors.white;
        label = 'Connect';
        icon = Icons.add_rounded;
        break;
      case StudioConnectionStatus.pending:
        buttonColor = AppColors.primary.withValues(alpha: 0.12);
        textColor = AppColors.primary;
        label = 'Pending Request';
        icon = Icons.hourglass_empty_rounded;
        break;
      case StudioConnectionStatus.connected:
        buttonColor = AppColors.success;
        textColor = Colors.white;
        label = 'Connected';
        icon = Icons.check_rounded;
        break;
    }

    return AnimatedContainer(
      duration: AppDurations.fast,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: isPendingCall ? null : () => _handleTap(context, ref),
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonColor,
          foregroundColor: textColor,
          elevation: status == StudioConnectionStatus.notConnected ? 2 : 0,
          shadowColor: status == StudioConnectionStatus.notConnected
              ? AppColors.primary.withValues(alpha: 0.4)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: status == StudioConnectionStatus.pending
                ? const BorderSide(color: AppColors.primary, width: 1)
                : BorderSide.none,
          ),
          padding: EdgeInsets.symmetric(horizontal: 16),
        ),
        icon: isPendingCall
            ? SizedBox(
                width: 16,
                height: 16,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: textColor),
              )
            : Icon(icon, size: 18),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
