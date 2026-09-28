import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/app_info_provider.dart';
import '../../providers/auth_providers.dart';
import '../../providers/client_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../../providers/face_search_provider.dart';
import '../../screens/client/client_saved_galleries_screen.dart';
import '../../main.dart'; // For navigatorKey
import 'drawer_menu_item.dart';

class ClientDrawer extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onNavigateToTab;

  const ClientDrawer({
    super.key,
    required this.currentIndex,
    required this.onNavigateToTab,
  });

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
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
              photographerName: '',
              email: '',
              clientId: '',
            ),
          );

      navigatorKey.currentState!.pushNamedAndRemoveUntil(
        AppRoutes.roleSelection,
        (route) => false,
      );
    }
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final authUser = ref.watch(authProvider).valueOrNull;
    final clientNotifier = ref.watch(clientProvider);
    final connections = ref.watch(connectionsProvider).valueOrNull ?? [];
    final pendingInviteCount = connections
        .where((c) => c.status == ConnectionStatus.pendingStudioRequest)
        .length;
    final connectedStudioCount =
        connections.where((c) => c.status == ConnectionStatus.connected).length;

    final client =
        clientNotifier.findByEmail(authUser?.email ?? settings.email);
    final clientName = (authUser?.fullName.trim().isNotEmpty ?? false)
        ? authUser!.fullName.trim()
        : (settings.photographerName.isNotEmpty
            ? settings.photographerName
            : 'Client');
    final clientEmail = (authUser?.email.trim().isNotEmpty ?? false)
        ? authUser!.email.trim()
        : (settings.email.isNotEmpty ? settings.email : 'No email set');
    final initial = clientName.isNotEmpty ? clientName[0].toUpperCase() : '?';
    final avatarUrl = authUser?.avatarUrl ?? client?.avatarUrl ?? '';

    // Responsive width
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth < 420 ? screenWidth * 0.82 : 340.0;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Drawer(
      width: drawerWidth,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.background,
      child: Column(
        children: [
          // 1. Profile Header
          InkWell(
            onTap: () {
              Navigator.of(context).pop(); // Close drawer
              // AppRoutes.profile ('/profile') has no matching case in
              // AppRoutes.onGenerateRoute — it falls through to the
              // `default:` branch, which just pops (or, if there's
              // nothing to pop to, redirects to the Studio's adminHome).
              // Either way this silently did nothing for a client. The
              // real Profile screen only exists as tab index 3 inside
              // MainNavScreen — same destination the "Settings" item
              // below already reaches correctly.
              onNavigateToTab(3);
            },
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                MediaQuery.of(context).padding.top + AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primary, AppColors.accent],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.24),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: avatarUrl.isNotEmpty
                        ? ClipOval(
                            child: avatarUrl.startsWith('http')
                                ? Image.network(avatarUrl,
                                    fit: BoxFit.cover, width: 56, height: 56)
                                : Image.file(File(avatarUrl),
                                    fit: BoxFit.cover, width: 56, height: 56),
                          )
                        : Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          clientName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          clientEmail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit_rounded,
                                  color: Colors.white, size: 10),
                              SizedBox(width: 4),
                              Text(
                                'View Profile',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. Drawer Items List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              children: [
                _buildSectionHeader(context, 'Main Navigation'),
                DrawerMenuItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  selected: currentIndex == 0,
                  onTap: () {
                    Navigator.of(context).pop();
                    onNavigateToTab(0);
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.search_rounded,
                  label: 'Discover Studios',
                  selected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pushNamed(AppRoutes.discoverStudios);
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.link_rounded,
                  label: 'Connected Studios',
                  selected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    onNavigateToTab(
                        0); // Switches to Home tab where Connected Studios lives
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.mail_outline_rounded,
                  label: 'Studio Invitations',
                  selected: false,
                  badgeCount: pendingInviteCount,
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pushNamed(AppRoutes.invitations);
                  },
                ),

                Divider(
                    height: AppSpacing.md,
                    thickness: 1,
                    color: Theme.of(context).dividerColor),
                _buildSectionHeader(context, 'Media & Galleries'),
                DrawerMenuItem(
                  icon: Icons.photo_library_rounded,
                  label: 'My Galleries',
                  selected: currentIndex == 1,
                  onTap: () {
                    Navigator.of(context).pop();
                    onNavigateToTab(1);
                  },
                ),
                // "Folders" and "Collections" removed: GET /folders and
                // GET /collections are studio-only (get_current_studio_user)
                // and 403 for a client account — there is no client-facing
                // folder/collection concept yet. Re-add once a client-scoped
                // backend route exists for either (mirrors the same removal
                // already done on the client Home screen).
                DrawerMenuItem(
                  icon: Icons.favorite_rounded,
                  label: 'Favorites',
                  selected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ClientSavedGalleriesScreen(),
                      ),
                    );
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.face_retouching_natural_rounded,
                  label: 'Face Search',
                  selected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    ref.read(faceSearchProvider.notifier).useClientGallery();
                    Navigator.of(context)
                        .pushNamed(AppRoutes.faceSearchLanding);
                  },
                ),
                // "Download History" removed: GET /download-history is
                // studio-only (get_current_studio_user) and 403s for a
                // client account — no client-facing download-history route
                // exists yet. Re-add once one does.

                Divider(
                    height: AppSpacing.md,
                    thickness: 1,
                    color: Theme.of(context).dividerColor),
                _buildSectionHeader(context, 'Account Settings'),
                DrawerMenuItem(
                  icon: Icons.notifications_rounded,
                  label: 'Notifications',
                  selected: currentIndex == 2,
                  onTap: () {
                    Navigator.of(context).pop();
                    onNavigateToTab(2);
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.settings_rounded,
                  label: 'Settings',
                  selected: currentIndex == 3,
                  onTap: () {
                    Navigator.of(context).pop();
                    onNavigateToTab(3);
                  },
                ),
                DrawerMenuItem(
                  icon: Icons.support_agent_rounded,
                  label: 'Help & Support',
                  selected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pushNamed(AppRoutes.helpSupport);
                  },
                ),
              ],
            ),
          ),

          // 3. Logout Item at Bottom
          Divider(
              height: 1, thickness: 1, color: Theme.of(context).dividerColor),
          _BottomSection(
            isDark: settings.themeMode == 'Dark',
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
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Dark mode toggle.
            Row(
              children: [
                const Icon(Icons.dark_mode_outlined,
                    size: 20, color: AppColors.primary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text('Dark Mode',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: onSurface)),
                ),
                Switch(
                  value: isDark,
                  onChanged: onToggleDark,
                ),
              ],
            ),
            // About App.
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: onAboutTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: onSurfaceVariant),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text('About App',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: onSurface)),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: onSurfaceVariant),
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
                  color: onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Logout — red, with confirmation dialog.
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
