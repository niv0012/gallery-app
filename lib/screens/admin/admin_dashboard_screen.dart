import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/admin_dashboard_data.dart';
import '../../providers/admin_dashboard_providers.dart';
import '../media/media_grid_screen.dart' show MediaSearchArgs;
import '../../upload/upload_queue_provider.dart';
import '../../widgets/admin/activity_timeline_tile.dart';
import '../../widgets/admin/analytics_chart_card.dart';
import '../../widgets/admin/fade_slide_in.dart';
import '../../widgets/admin/quick_action_handler.dart';
import '../../widgets/admin/quick_action_tile.dart';
import '../../widgets/admin/recent_client_tile.dart';
import '../../widgets/admin/recent_upload_card.dart';
import '../../widgets/admin/section_header.dart';
import '../../widgets/admin/stat_card.dart';
import '../../widgets/admin/storage_usage_card.dart';
import '../../widgets/admin/welcome_card.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/navigation/studio_drawer.dart';

/// Studio Dashboard — the Photographer/Studio Owner's home tab.
///
/// Fully light-themed (matches the rest of the app's soft-lavender
/// picgallery palette — no dark canvas) and fully dynamic: every number,
/// list and chart on this screen comes from [adminDashboardProvider],
/// which is backed by [AdminDashboardRepository]. There is no
/// compile-time/dummy data anywhere in this widget — creating a booking,
/// uploading a photo, adding a client, etc. (from here or anywhere else
/// in the app) is reflected here immediately.
class StudioDashboardScreen extends ConsumerStatefulWidget {
  const StudioDashboardScreen({super.key, this.onNavigateToTab});

  final ValueChanged<int>? onNavigateToTab;

  @override
  ConsumerState<StudioDashboardScreen> createState() =>
      _StudioDashboardScreenState();
}

class _StudioDashboardScreenState extends ConsumerState<StudioDashboardScreen>
    with RouteAware {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    ref.read(adminDashboardProvider.notifier).refresh();
  }

  void _toast(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color ??
            (Theme.of(context).brightness == Brightness.dark
                ? AppColors.textOnDark
                : AppColors.text),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// Starts a fresh upload with no preset album/folder — the wizard's
  /// own Options step lets the user file it (or leave it unfiled) from
  /// here. Deliberately only wired up on this screen and on Folder
  /// Details, per the "Add Media" FAB's intended scope — it should not
  /// appear on every screen.
  Future<void> _addMedia() async {
    final notifier = ref.read(uploadQueueProvider.notifier);
    await notifier.resetWizard();
    if (!mounted) return;
    Navigator.of(context).pushNamed(AppRoutes.uploadQueue);
  }

  @override
  Widget build(BuildContext context) {
    final dashboardAsync = ref.watch(adminDashboardProvider);

    return Scaffold(
      key: _scaffoldKey,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'dashboard_add_media_fab',
        onPressed: _addMedia,
        icon: Icon(Icons.add_photo_alternate_rounded),
        label: Text('Add Media'),
      ),
      drawer: StudioDrawer(onNavigateToTab: widget.onNavigateToTab),
      appBar: CustomAppBar(
        showBack: false,
        leading: Padding(
          padding: EdgeInsets.only(left: 12),
          child: GlassIconButton(
            icon: Icons.menu_rounded,
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        ),
        titleWidget: ShaderMask(
          shaderCallback: (bounds) =>
              AppColors.heroGradient.createShader(bounds),
          child: Text(
            'PicGallery Studio',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        actions: [
          dashboardAsync.maybeWhen(
            data: (snapshot) => Padding(
              padding: EdgeInsets.only(right: 4),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: Icon(Icons.notifications_none_rounded,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                        size: 24),
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.notifications),
                  ),
                  if (snapshot.unreadNotificationCount > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding:
                            EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          border: Border.all(
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.darkBackground
                                  : AppColors.background),
                              width: 1.5),
                        ),
                        child: Text(
                          '${snapshot.unreadNotificationCount}',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            orElse: () => IconButton(
              icon: Icon(Icons.notifications_none_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text),
                  size: 24),
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.notifications),
            ),
          ),
          SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: dashboardAsync.when(
          loading: () => Center(
              child: CircularProgressIndicator(color: AppColors.primary)),
          error: (err, _) => Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded,
                      color: AppColors.error, size: 40),
                  SizedBox(height: AppSpacing.md),
                  Text('Could not load your dashboard\n$err',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          fontSize: 13)),
                  SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(adminDashboardProvider.notifier).refresh(),
                    icon: Icon(Icons.refresh_rounded, size: 18),
                    label: Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          data: (snapshot) => RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () =>
                ref.read(adminDashboardProvider.notifier).refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.md),
              children: [
                ..._buildHeaderGreeting(snapshot),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  child: WelcomeCard(
                    pendingDeliveries: snapshot.pendingDeliveriesCount,
                  ),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: _buildStatsGrid(snapshot),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 100),
                  child: _buildQuickActions(snapshot),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 120),
                  child: SectionHeader(
                    title: 'Recent Uploads',
                    onAction: () => widget.onNavigateToTab?.call(1),
                  ),
                ),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 120),
                  child: _buildRecentUploads(snapshot),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 180),
                  child: SectionHeader(
                    title: 'Storage Overview',
                    onAction: () => Navigator.of(context)
                        .pushNamed(AppRoutes.storageOverview),
                  ),
                ),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 180),
                  child: StorageUsageCard(
                    usedLabel: _storageStat(snapshot).value,
                    totalLabel: '',
                    onTap: () => Navigator.of(context)
                        .pushNamed(AppRoutes.storageOverview),
                  ),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 220),
                  child: SectionHeader(
                    title: 'Recent Clients',
                    onAction: () => widget.onNavigateToTab?.call(2),
                  ),
                ),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 220),
                  child: _buildRecentClients(snapshot),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 260),
                  child: SectionHeader(
                    title: 'Performance',
                    actionLabel: 'Full report',
                    onAction: () => Navigator.of(context)
                        .pushNamed(AppRoutes.adminAnalytics),
                  ),
                ),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 260),
                  child: _buildAnalyticsCarousel(snapshot),
                ),
                SizedBox(height: AppSpacing.xl),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 300),
                  child: SectionHeader(
                    title: 'Recent Activity',
                    onAction: () => Navigator.of(context)
                        .pushNamed(AppRoutes.recentActivity),
                  ),
                ),
                SizedBox(height: AppSpacing.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 300),
                  child: ActivityTimelineList(
                      entries: snapshot.activityLog.take(5).toList()),
                ),
                SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildHeaderGreeting(AdminDashboardSnapshot snapshot) {
    final hasPhotographerName = snapshot.photographerName.trim().isNotEmpty;
    final hasStudioName = snapshot.studioName.trim().isNotEmpty;
    final colorScheme = Theme.of(context).colorScheme;

    if (!hasPhotographerName && !hasStudioName) {
      return [
        Text(
          'Hi there 👋',
          style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurfaceVariant),
        ),
        SizedBox(height: 2),
        Text(
          'Set up your studio profile',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: colorScheme.onSurface,
              letterSpacing: -0.3),
        ),
      ];
    }

    return [
      Text(
        hasPhotographerName
            ? 'Hi, ${snapshot.photographerName} 👋'
            : 'Hi there 👋',
        style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurfaceVariant),
      ),
      SizedBox(height: 2),
      Text(
        hasStudioName ? snapshot.studioName : 'Set up your studio profile',
        style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: colorScheme.onSurface,
            letterSpacing: -0.3),
      ),
    ];
  }

  Widget _buildRecentUploads(AdminDashboardSnapshot snapshot) {
    final uploads = snapshot.recentUploads.take(6).toList();
    if (uploads.isEmpty) {
      return const EmptyStateCard(
          icon: Icons.cloud_upload_rounded,
          message: 'No uploads yet — upload your first photos or videos');
    }
    return SizedBox(
      height: 175,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: uploads.length,
        separatorBuilder: (_, __) => SizedBox(width: AppSpacing.md),
        itemBuilder: (context, i) {
          final upload = uploads[i];
          return SizedBox(
            width: 140,
            child: InkWell(
              onTap: () {
                if (upload.albumId == null) {
                  Navigator.of(context).pushNamed(
                    AppRoutes.media,
                  );
                } else {
                  Navigator.of(context).pushNamed(
                    AppRoutes.adminAlbumDetails,
                    arguments: upload.albumId,
                  );
                }
              },
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: RecentUploadCard(data: upload),
            ),
          );
        },
      ),
    );
  }

  StatCardData _storageStat(AdminDashboardSnapshot snapshot) =>
      snapshot.stats.firstWhere((s) => s.label == 'Storage Used',
          orElse: () => snapshot.stats.first);

  int _calculateCrossAxisCount(double width) {
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }

  Widget _buildStatsGrid(AdminDashboardSnapshot snapshot) {
    if (snapshot.stats.isEmpty) {
      return const EmptyStateCard(
          icon: Icons.bar_chart_rounded, message: 'No studio stats yet');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: snapshot.stats.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            mainAxisExtent: 180,
          ),
          itemBuilder: (context, i) => StatCard(data: snapshot.stats[i]),
        );
      },
    );
  }

  Widget _buildQuickActions(AdminDashboardSnapshot snapshot) {
    final actions = snapshot.quickActions.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Quick Actions',
          onAction: () {
            Navigator.of(context)
                .pushNamed(AppRoutes.quickActions)
                .then((tabIndex) {
              if (tabIndex is int && context.mounted) {
                widget.onNavigateToTab?.call(tabIndex);
              }
            });
          },
        ),
        SizedBox(height: AppSpacing.md),
        if (actions.isEmpty)
          const EmptyStateCard(
              icon: Icons.bolt_rounded, message: 'No quick actions available')
        else
          SizedBox(
            height: 108,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: actions.length,
              separatorBuilder: (_, __) => SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, i) {
                final action = actions[i];
                return SizedBox(
                  width: 92,
                  child: QuickActionTile(
                    data: action,
                    onTap: () => QuickActionHandler.execute(
                      context: context,
                      ref: ref,
                      action: action,
                      toast: _toast,
                      onNavigateToTab: widget.onNavigateToTab,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildRecentClients(AdminDashboardSnapshot snapshot) {
    final clients = snapshot.clients.take(3).toList();
    if (clients.isEmpty) {
      return const EmptyStateCard(
          icon: Icons.people_alt_rounded,
          message: 'No clients yet — add your first one from Quick Actions');
    }
    return Column(
      children: [
        for (final client in clients) ...[
          RecentClientTile(data: client),
          if (client != clients.last) SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  Widget _buildAnalyticsCarousel(AdminDashboardSnapshot snapshot) {
    if (snapshot.analytics.isEmpty) {
      return const EmptyStateCard(
          icon: Icons.insights_rounded, message: 'No performance data yet');
    }
    return SizedBox(
      height: 216,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: snapshot.analytics.length,
        separatorBuilder: (_, __) => SizedBox(width: AppSpacing.md),
        itemBuilder: (context, i) =>
            AnalyticsChartCard(series: snapshot.analytics[i]),
      ),
    );
  }
}
