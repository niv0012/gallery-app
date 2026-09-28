import 'package:flutter/material.dart';

import '../../core/api/admin_api_client.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format_utils.dart';
import 'super_admin_profile_screen.dart';
import 'super_admin_storage_screen.dart';
import 'super_admin_subscriptions_screen.dart';
import 'super_admin_users_screen.dart';
import '../../core/theme/theme_context.dart';

class _DashboardData {
  final PlatformUsers users;
  final StorageSummary storage;
  _DashboardData(this.users, this.storage);
}

const double kStorageWarningThreshold = 80.0; // %
const double kStorageCriticalThreshold = 95.0; // %

class SuperAdminDashboardScreen extends StatefulWidget {
  const SuperAdminDashboardScreen({super.key});

  @override
  State<SuperAdminDashboardScreen> createState() => _SuperAdminDashboardScreenState();
}

class _SuperAdminDashboardScreenState extends State<SuperAdminDashboardScreen> {
  late Future<_DashboardData> _dashboardFuture;

  @override
  void initState() {
    super.initState();
    _dashboardFuture = _loadData();
  }

  Future<_DashboardData> _loadData() async {
    final results = await Future.wait([
      AdminApiClient.instance.fetchUsers(),
      AdminApiClient.instance.fetchStorageSummary(),
    ]);
    return _DashboardData(
      results[0] as PlatformUsers,
      results[1] as StorageSummary,
    );
  }

  Future<void> _refresh() async {
    final future = _loadData();
    setState(() {
      _dashboardFuture = future;
    });
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        automaticallyImplyLeading: false,
        titleSpacing: AppSpacing.md,
        title: Text(
          'Super Admin',
          style: TextStyle(
            color: context.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.account_circle_rounded, color: context.textMuted),
            tooltip: 'Profile',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SuperAdminProfileScreen()),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<_DashboardData>(
        future: _dashboardFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded, color: context.textMuted, size: 32),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error is AdminApiException
                          ? (snapshot.error as AdminApiException).message
                          : 'Could not load dashboard data.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.textMuted),
                    ),
                    const SizedBox(height: 12),
                    TextButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }

          final data = snapshot.data!;
          final users = data.users;
          final storage = data.storage;
          final studios = users.studios;
          final clients = users.clients;
          final activeSubs = studios
              .where((s) =>
                  s.subscriptionStatus == 'active' ||
                  s.subscriptionStatus == 'trial')
              .length;
          final recentlyJoined = [...studios, ...clients]
              .toList()
            ..sort((a, b) => b.joinedAt.compareTo(a.joinedAt));
          final suspended =
              [...studios, ...clients].where((u) => !u.isActive).toList();

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                if (storage.usedPercentage >= kStorageWarningThreshold) ...[
                  _StorageWarningBanner(
                    usedPercentage: storage.usedPercentage,
                    usedBytes: storage.totalUsedBytes,
                    totalBytes: storage.totalCapacityBytes,
                    critical: storage.usedPercentage >= kStorageCriticalThreshold,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SuperAdminStorageScreen(
                        storageSummary: storage,
                        allUsers: [...studios, ...clients],
                      ),
                    )),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 1.25,
                  children: [
                    _Kpi(
                      icon: Icons.photo_camera_back_rounded,
                      gradient: const [AppColors.primary, AppColors.secondary],
                      label: 'Studio users',
                      value: '${studios.length}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SuperAdminUsersScreen(initialTab: 0),
                      )),
                    ),
                    _Kpi(
                      icon: Icons.people_alt_rounded,
                      gradient: const [AppColors.secondary, AppColors.accent],
                      label: 'Client users',
                      value: '${clients.length}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SuperAdminUsersScreen(initialTab: 1),
                      )),
                    ),
                    _Kpi(
                      icon: Icons.cloud_queue_rounded,
                      gradient: const [AppColors.secondary, AppColors.primary],
                      label: 'Storage Used',
                      value: '${formatBytes(storage.totalUsedBytes)} / ${formatBytes(storage.totalCapacityBytes)}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SuperAdminStorageScreen(
                          storageSummary: storage,
                          allUsers: [...studios, ...clients],
                        ),
                      )),
                    ),
                    _Kpi(
                      icon: Icons.workspace_premium_rounded,
                      gradient: const [AppColors.success, AppColors.primary],
                      label: 'Active subscriptions',
                      value: '$activeSubs',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SuperAdminSubscriptionsScreen(),
                      )),
                    ),

                    _Kpi(
                      icon: Icons.block_rounded,
                      gradient: const [AppColors.error, AppColors.secondary],
                      label: 'Suspended accounts',
                      value: '${suspended.length}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SuperAdminUsersScreen(
                          initialTab: 0,
                          suspendedOnly: true,
                        ),
                      )),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Recently joined',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: context.textPrimary),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (recentlyJoined.isEmpty)
                  const _EmptySection(label: 'No users yet')
                else
                  ...recentlyJoined.take(4).map((u) => _RecentUserTile(user: u)),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Suspended accounts',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700, color: context.textPrimary),
                    ),
                    if (suspended.length > 4)
                      TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const SuperAdminUsersScreen(
                            initialTab: 0,
                            suspendedOnly: true,
                          ),
                        )),
                        child: const Text('View all', style: TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Accounts a Super Admin has suspended.',
                  style: TextStyle(fontSize: 12.5, color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (suspended.isEmpty)
                  const _EmptySection(label: 'None found')
                else
                  ...suspended.take(4).map((u) => _RecentUserTile(user: u, showSuspendedBadge: true)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  final String label;
  const _EmptySection({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(label, style: TextStyle(color: context.textMuted, fontSize: 12.5)),
    );
  }
}

class _Kpi extends StatelessWidget {
  final IconData icon;
  final List<Color> gradient;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _Kpi({
    required this.icon,
    required this.gradient,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: context.borderColor),
          boxShadow: [
            BoxShadow(
                color: gradient.last.withValues(alpha: 0.10),
                blurRadius: 20,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: gradient),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 19),
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentUserTile extends StatelessWidget {
  final PlatformUser user;
  final bool showSuspendedBadge;
  const _RecentUserTile({
    required this.user,
    this.showSuspendedBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final isStudio = user.isStudio;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: showSuspendedBadge
                ? AppColors.error.withValues(alpha: 0.4)
                : context.borderColor),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: (isStudio ? AppColors.primary : AppColors.accent)
                .withValues(alpha: 0.12),
            child: Text(user.initials,
                style: TextStyle(
                    color: isStudio ? AppColors.primary : AppColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text(user.email,
                    style: TextStyle(fontSize: 11.5, color: context.textMuted)),
              ],
            ),
          ),
          if (showSuspendedBadge)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: const Text('Suspended',
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.error)),
            )
          else
            Text(isStudio ? 'Studio' : 'Client',
                style: TextStyle(fontSize: 11, color: context.textMuted)),
        ],
      ),
    );
  }
}

class _StorageWarningBanner extends StatelessWidget {
  final double usedPercentage;
  final int usedBytes;
  final int totalBytes;
  final bool critical;
  final VoidCallback? onTap;

  const _StorageWarningBanner({
    required this.usedPercentage,
    required this.usedBytes,
    required this.totalBytes,
    required this.critical,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = critical ? AppColors.error : AppColors.warning;
    final pctStr = usedPercentage.toStringAsFixed(1);
    final text = critical
        ? 'Storage critically full — $pctStr% used. Uploads may start failing.'
        : 'Storage nearly full — $pctStr% used (${formatBytes(usedBytes)} of ${formatBytes(totalBytes)})';

    final content = Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            critical ? Icons.error_rounded : Icons.warning_amber_rounded,
            color: color,
            size: 24,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(
              Icons.chevron_right_rounded,
              color: color,
              size: 20,
            ),
          ],
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}