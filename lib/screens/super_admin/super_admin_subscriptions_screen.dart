import 'package:flutter/material.dart';

import '../../core/api/admin_api_client.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import 'super_admin_user_detail_screen.dart';
import '../../core/theme/theme_context.dart';

/// Cross-cutting view of "which studios currently pay a platform
/// subscription" — pulled from the same GET /admin/users data as the
/// Studio Users tab, filtered/sorted around `subscriptionStatus`
/// instead of profile info.
class SuperAdminSubscriptionsScreen extends StatefulWidget {
  const SuperAdminSubscriptionsScreen({super.key});

  @override
  State<SuperAdminSubscriptionsScreen> createState() =>
      _SuperAdminSubscriptionsScreenState();
}

// Order/labels/colors for the filter chips — mirrors the backend's
// `subscription_status` values (see SubscriptionStatusX on String in
// admin_api_client.dart).
const _statuses = ['active', 'trial', 'expired', 'none'];

class _SuperAdminSubscriptionsScreenState
    extends State<SuperAdminSubscriptionsScreen> {
  String? _filter;
  late Future<PlatformUsers> _usersFuture;

  @override
  void initState() {
    super.initState();
    _usersFuture = AdminApiClient.instance.fetchUsers();
  }

  Future<void> _refresh() async {
    final future = AdminApiClient.instance.fetchUsers();
    setState(() {
      _usersFuture = future;
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
        title: Text('Subscriptions',
            style: TextStyle(
                color: context.textPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: FutureBuilder<PlatformUsers>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.textMuted)),
                    const SizedBox(height: AppSpacing.md),
                    OutlinedButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }

          final allStudios = snapshot.data!.studios;
          final studios = allStudios
              .where((s) => _filter == null || s.subscriptionStatus == _filter)
              .toList();
          final counts = {
            for (final status in _statuses)
              status: allStudios.where((s) => s.subscriptionStatus == status).length,
          };

          return RefreshIndicator(
            onRefresh: _refresh,
            child: Column(
              children: [
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    children: [
                      _FilterChip(
                        label: 'All',
                        count: allStudios.length,
                        selected: _filter == null,
                        color: context.textPrimary,
                        onTap: () => setState(() {
                          _filter = null;
                        }),
                      ),
                      for (final status in _statuses)
                        _FilterChip(
                          label: status.subscriptionLabel,
                          count: counts[status] ?? 0,
                          selected: _filter == status,
                          color: status.subscriptionColor,
                          onTap: () => setState(() {
                            _filter = status;
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: studios.isEmpty
                      ? ListView(
                          // Wrapped in a ListView (not a bare Center) so
                          // pull-to-refresh still works on an empty filter.
                          children: [
                            SizedBox(height: 120),
                            Center(
                              child: Text('No studios in this filter',
                                  style: TextStyle(color: context.textMuted)),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
                          itemCount: studios.length,
                          itemBuilder: (context, i) => _SubscriptionTile(
                            studio: studios[i],
                            onChanged: _refresh,
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.12) : context.surfaceColor,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: selected ? color : context.borderColor),
          ),
          child: Text('$label · $count',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? color : context.textMuted)),
        ),
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  final PlatformUser studio;
  final VoidCallback? onChanged;
  const _SubscriptionTile({required this.studio, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: context.borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => SuperAdminUserDetailScreen(user: studio),
            ),
          );
          if (changed == true) onChanged?.call();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: studio.subscriptionStatus.subscriptionColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(studio.studioName ?? studio.fullName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13.5)),
                      Text(
                        _buildSubtitle(studio),
                        style: TextStyle(fontSize: 11.5, color: context.textMuted),
                      ),
                    ],
                  ),
              ),
              if (!studio.isActive) ...[
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.block_rounded, size: 15, color: AppColors.error),
                ),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: studio.subscriptionStatus.subscriptionColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(studio.subscriptionStatus.subscriptionLabel,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: studio.subscriptionStatus.subscriptionColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _planLabel(String plan) => switch (plan) {
        'trial' => 'Trial',
        'pro' => 'Pro',
        'premium' => 'Premium',
        _ => plan,
      };

  String _buildSubtitle(PlatformUser studio) {
    if (studio.currentPlan != null) {
      final planName = _planLabel(studio.currentPlan!);
      
      String? startStr;
      if (studio.planStartedAt != null) {
        final st = studio.planStartedAt!;
        final min = st.minute.toString().padLeft(2, '0');
        final hr = st.hour.toString().padLeft(2, '0');
        startStr = '${st.day}/${st.month}/${st.year} $hr:$min';
      }

      if (studio.planExpiry != null) {
        final d = studio.planExpiry!;
        final min = d.minute.toString().padLeft(2, '0');
        final hr = d.hour.toString().padLeft(2, '0');
        final dateStr = '${d.day}/${d.month}/${d.year} $hr:$min';
        
        final base = startStr != null 
            ? '${studio.email}\n$planName (Taken: $startStr)'
            : '${studio.email}\n$planName';

        return studio.subscriptionStatus == 'expired'
            ? '$base, expired $dateStr'
            : '$base, until $dateStr';
      }
      return startStr != null 
          ? '${studio.email}\n$planName (Taken: $startStr)'
          : '${studio.email}\n$planName';
    }
    return studio.email;
  }
}
