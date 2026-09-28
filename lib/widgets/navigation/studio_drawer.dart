import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/admin_dashboard_providers.dart';
import '../../providers/app_info_provider.dart';
import '../../providers/auth_providers.dart';
import '../../providers/drawer_provider.dart';
import '../../providers/face_search_provider.dart';
import '../../providers/settings_provider.dart';
import '../../main.dart'; // For navigatorKey
import 'drawer_header.dart';

/// How a drawer action behaves when tapped.
enum _DrawerAction {
  /// Switches the bottom-nav tab on [AdminMainNavScreen].
  tab,

  /// Pushes a named route via [AppRoutes.onGenerateRoute].
  route,
}

/// Production Navigation Drawer for the Studio Dashboard.
///
/// Organized into meaningful sections with premium hover, selected indicators,
/// and a highlighted Business Subscription management row.
class StudioDrawer extends ConsumerWidget {
  const StudioDrawer({super.key, this.onNavigateToTab});

  /// Lets Dashboard-tab items (Albums, Clients, Dashboard itself)
  /// switch the parent [AdminMainNavScreen] bottom-nav tab instead of
  /// pushing a duplicate screen on top of it.
  final ValueChanged<int>? onNavigateToTab;

  void _handleTap(
    BuildContext context,
    WidgetRef ref,
    String id,
    _DrawerAction action, {
    int? tabIndex,
    String? routeName,
  }) {
    ref.read(selectedDrawerItemProvider.notifier).select(id);
    final nav = Navigator.of(context);
    nav.pop(); // close the drawer first

    switch (action) {
      case _DrawerAction.tab:
        onNavigateToTab?.call(tabIndex!);
        break;
      case _DrawerAction.route:
        _openRoute(nav, routeName!);
        break;
    }
  }

  /// Opens [routeName] without ever stacking a second copy of a page that is
  /// already open: no-op if it is on top, unwinds to it if it is deeper in
  /// the stack, otherwise pushes it.
  static void _openRoute(NavigatorState nav, String routeName) {
    if (routeObserver.currentRouteName == routeName) return;
    if (routeObserver.isInStack(routeName)) {
      nav.popUntil((r) => r.settings.name == routeName);
      return;
    }
    nav.pushNamed(routeName);
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Logout?'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final container = ProviderScope.containerOf(context, listen: false);
      container.read(authProvider.notifier).logout();
      final currentSettings = container.read(settingsProvider);
      container.read(settingsProvider.notifier).updateSettings(
            currentSettings.copyWith(
              studioName: '',
              photographerName: '',
              email: '',
            ),
          );

      container.read(selectedDrawerItemProvider.notifier).select('dashboard');

      navigatorKey.currentState!.pushNamedAndRemoveUntil(AppRoutes.roleSelection, (route) => false);
    }
  }

  void _showAbout(BuildContext context, WidgetRef ref) {
    final version = ref.read(appVersionLabelProvider).when(
          data: (value) => value,
          loading: () => '',
          error: (_, __) => '',
        );
    showAboutDialog(
      context: context,
      applicationName: AppStrings.appName,
      applicationVersion: version,
      applicationIcon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
            gradient: AppColors.heroGradient,
            borderRadius: BorderRadius.circular(AppRadius.sm)),
        alignment: Alignment.center,
        child:
            const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 22),
      ),
      children: const [Text(AppStrings.tagline)],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md + AppSpacing.xs,
          AppSpacing.md, AppSpacing.md, AppSpacing.xs),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedDrawerItemProvider);
    final settings = ref.watch(settingsProvider);
    final unreadCount =
        ref.watch(adminDashboardProvider).value?.unreadNotificationCount ?? 0;

    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth < 420
        ? screenWidth * 0.84
        : (screenWidth < 900 ? 340.0 : 380.0);

    final isDark = settings.themeMode == 'Dark';

    final theme = Theme.of(context);

    return Drawer(
      width: drawerWidth,
      backgroundColor: theme.colorScheme.surface,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.horizontal(right: Radius.circular(AppRadius.lg)),
      ),
      child: Column(
        children: [
          const StudioDrawerHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              physics: const BouncingScrollPhysics(),
              children: [
                _buildSectionHeader(context, 'STUDIO'),
                _StudioDrawerTile(
                  icon: Icons.dashboard_rounded,
                  label: 'Dashboard',
                  selected: selectedId == 'dashboard',
                  onTap: () => _handleTap(
                      context, ref, 'dashboard', _DrawerAction.tab,
                      tabIndex: 0),
                ),
                _StudioDrawerTile(
                  icon: Icons.notifications_rounded,
                  label: 'Notifications',
                  selected: selectedId == 'notifications',
                  badgeCount: unreadCount,
                  onTap: () => _handleTap(
                      context, ref, 'notifications', _DrawerAction.route,
                      routeName: AppRoutes.notifications),
                ),
                _StudioDrawerTile(
                  icon: Icons.bar_chart_rounded,
                  label: 'Analytics',
                  selected: selectedId == 'reports',
                  onTap: () => _handleTap(
                      context, ref, 'reports', _DrawerAction.route,
                      routeName: AppRoutes.adminAnalytics),
                ),
                _StudioDrawerTile(
                  icon: Icons.photo_library_rounded,
                  label: 'Gallery',
                  selected: selectedId == 'gallery',
                  onTap: () => _handleTap(
                      context, ref, 'gallery', _DrawerAction.tab,
                      tabIndex: 1),
                ),
                _buildSectionHeader(context, 'CONTENT'),
                _StudioDrawerTile(
                  icon: Icons.folder_rounded,
                  label: 'Folders',
                  selected: selectedId == 'folders',
                  onTap: () => _handleTap(
                      context, ref, 'folders', _DrawerAction.route,
                      routeName: AppRoutes.adminFolderList),
                ),
                _StudioDrawerTile(
                  icon: Icons.perm_media_rounded,
                  label: 'Media',
                  selected: selectedId == 'media',
                  onTap: () => _handleTap(
                      context, ref, 'media', _DrawerAction.route,
                      routeName: AppRoutes.media),
                ),
                _StudioDrawerTile(
                  icon: Icons.cloud_upload_rounded,
                  label: 'Uploads',
                  selected: selectedId == 'uploads',
                  onTap: () => _handleTap(
                      context, ref, 'uploads', _DrawerAction.route,
                      routeName: AppRoutes.uploadQueue),
                ),
                _StudioDrawerTile(
                  icon: Icons.face_retouching_natural_rounded,
                  label: 'Face Search',
                  selected: selectedId == 'face_search',
                  onTap: () {
                    ref
                        .read(selectedDrawerItemProvider.notifier)
                        .select('face_search');
                    final nav = Navigator.of(context);
                    nav.pop();
                    // Scopes the search to the studio's own library —
                    // same POST /faces/search endpoint, mirrors the
                    // AppBar action on AlbumsListScreen.
                    ref.read(faceSearchProvider.notifier).useMyLibrary();
                    _openRoute(nav, AppRoutes.faceSearchLanding);
                  },
                ),
                _buildSectionHeader(context, 'RELATIONSHIPS'),
                _StudioDrawerTile(
                  icon: Icons.people_rounded,
                  label: 'Clients',
                  selected: selectedId == 'clients',
                  onTap: () => _handleTap(
                      context, ref, 'clients', _DrawerAction.tab,
                      tabIndex: 2),
                ),
                _buildSectionHeader(context, 'BUSINESS'),
                _SubscriptionDrawerTile(
                  selected: selectedId == 'subscription_plans',
                  onTap: () => _handleTap(
                      context, ref, 'subscription_plans', _DrawerAction.route,
                      routeName: AppRoutes.subscriptionPlans),
                ),
                _buildSectionHeader(context, 'SETTINGS'),
                _StudioDrawerTile(
                  icon: Icons.settings_rounded,
                  label: 'Studio Settings',
                  selected: selectedId == 'settings',
                  onTap: () => _handleTap(
                      context, ref, 'settings', _DrawerAction.route,
                      routeName: AppRoutes.adminSettings),
                ),
                _StudioDrawerTile(
                  icon: Icons.support_agent_rounded,
                  label: 'Help & Support',
                  selected: selectedId == 'help',
                  onTap: () => _handleTap(
                      context, ref, 'help', _DrawerAction.route,
                      routeName: AppRoutes.helpSupport),
                ),
                _StudioDrawerTile(
                  icon: Icons.privacy_tip_outlined,
                  label: 'Privacy Policy',
                  selected: selectedId == 'privacy',
                  onTap: () => _handleTap(
                      context, ref, 'privacy', _DrawerAction.route,
                      routeName: AppRoutes.privacyPolicy),
                ),
                _StudioDrawerTile(
                  icon: Icons.description_outlined,
                  label: 'Terms & Conditions',
                  selected: selectedId == 'terms',
                  onTap: () => _handleTap(
                      context, ref, 'terms', _DrawerAction.route,
                      routeName: AppRoutes.termsConditions),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          _BottomSection(
            isDark: isDark,
            onToggleDark: (value) {
              ref.read(settingsProvider.notifier).updateSettings(
                    settings.copyWith(themeMode: value ? 'Dark' : 'Light'),
                  );
            },
            onAboutTap: () => _showAbout(context, ref),
            onLogoutTap: () => _confirmLogout(context),
            versionLabel: ref.watch(appVersionLabelProvider).when(
                  data: (value) => value,
                  loading: () => '',
                  error: (_, __) => '',
                ),
          ),
        ],
      ),
    );
  }
}

/// A premium, customizable drawer menu item row.
class _StudioDrawerTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  const _StudioDrawerTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  State<_StudioDrawerTile> createState() => _StudioDrawerTileState();
}

class _StudioDrawerTileState extends State<_StudioDrawerTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : (_hovering
                        ? AppColors.primary.withValues(alpha: 0.04)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: selected
                    ? Border.all(
                        color: AppColors.primary.withValues(alpha: 0.15),
                        width: 1)
                    : Border.all(color: Colors.transparent, width: 1),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  if (selected)
                    Container(
                      width: 3.5,
                      height: 16,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Icon(
                    widget.icon,
                    size: 20,
                    color: selected
                        ? AppColors.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected
                            ? AppColors.primary
                            : colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (widget.badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.primary : AppColors.accent,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        widget.badgeCount > 99 ? '99+' : '${widget.badgeCount}',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A highlighted custom Business Subscription drawer tile that stands out.
class _SubscriptionDrawerTile extends ConsumerWidget {
  final bool selected;
  final VoidCallback onTap;

  const _SubscriptionDrawerTile({
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const title = 'Premium Plan';
    const subtitle = 'Manage Subscription';
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.08)
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : colorScheme.outline.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    gradient: AppColors.heroGradient,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.2),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      )
                    ],
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? AppColors.primary
                              : colorScheme.onSurface,
                        ),
                      ),
                      const Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.gold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [AppColors.gold, Color(0xFFF59E0B)]),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Text(
                    'PREMIUM',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dark-mode toggle, version, and Logout — pinned to
/// the bottom of the drawer, below the scrollable menu.
class _BottomSection extends StatelessWidget {
  const _BottomSection({
    required this.isDark,
    required this.onToggleDark,
    required this.onAboutTap,
    required this.onLogoutTap,
    required this.versionLabel,
  });

  final bool isDark;
  final ValueChanged<bool> onToggleDark;
  final VoidCallback onAboutTap;
  final VoidCallback onLogoutTap;
  final String versionLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.dark_mode_outlined,
                    size: 20, color: colorScheme.primary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text('Dark Mode',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface)),
                ),
                Switch(
                  value: isDark,
                  onChanged: onToggleDark,
                ),
              ],
            ),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: onAboutTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text('About App',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface)),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              versionLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onLogoutTap,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Logout',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
