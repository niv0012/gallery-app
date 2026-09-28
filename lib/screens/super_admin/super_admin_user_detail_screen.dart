import 'package:flutter/material.dart';

import '../../core/api/admin_api_client.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format_utils.dart';
import '../../core/theme/theme_context.dart';

/// Detail view for a single Studio or Client account.
///
/// Takes the already-fetched `PlatformUser` (from GET /admin/users via
/// the Users screen) directly, rather than re-fetching by id — the
/// list screen already has the full record in memory. `linked` is the
/// same-email other-role account, pre-resolved by the caller (see
/// `_UserTile` in super_admin_users_screen.dart), so a "Linked
/// account" card appears when this email also has a Studio/Client
/// account under the other role. Nothing is auto-merged — they stay
/// two separate accounts/records, same as they are in the database;
/// this screen just makes the relationship visible.
class SuperAdminUserDetailScreen extends StatefulWidget {
  final PlatformUser user;
  const SuperAdminUserDetailScreen({super.key, required this.user});

  @override
  State<SuperAdminUserDetailScreen> createState() => _SuperAdminUserDetailScreenState();
}

class _SuperAdminUserDetailScreenState extends State<SuperAdminUserDetailScreen> {
  late PlatformUser _user;
  bool _updating = false;
  // True once a suspend/reactivate has actually succeeded here, so the
  // caller (Users list / Dashboard) knows to refresh instead of showing
  // stale status after we pop back.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
  }

  Future<void> _toggleSuspend() async {
    setState(() => _updating = true);
    try {
      final updated = _user.isActive
          ? await AdminApiClient.instance.suspendUser(_user.id)
          : await AdminApiClient.instance.unsuspendUser(_user.id);
      if (!mounted) return;
      setState(() {
        // BUGFIX: `users.update().select()` only returns raw `users`
        // table columns — `used_bytes` isn't one of them (it's computed
        // separately via the storage RPC). Without this copyWith, every
        // suspend/reactivate silently reset "Storage used" to 0 B on
        // this screen, even though nothing about the user's storage
        // actually changed.
        _user = updated.copyWith(usedBytes: _user.usedBytes);
        _updating = false;
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(updated.isActive
            ? 'Account reactivated.'
            : 'Account suspended — this user can no longer sign in.'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _updating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _planLabel(String? plan) => switch (plan) {
        'trial' => 'Trial',
        'pro' => 'Pro',
        'premium' => 'Premium',
        _ => 'Not subscribed',
      };

  String _dateTimeLabel(DateTime? dt) {
    if (dt == null) return '—';
    final minute = dt.minute.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final isStudio = user.isStudio;

    return PopScope(
      // Intercept every way of leaving this screen (AppBar back button,
      // hardware back button, iOS swipe-back gesture) so the caller
      // always finds out whether a suspend/reactivate happened here —
      // not just when the user taps a specific button.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(isStudio ? 'Studio account' : 'Client account',
            style: TextStyle(
                color: context.textPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              gradient: AppColors.heroGradient,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 34,
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  child: Text(user.initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 12),
                Text(user.fullName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(user.email,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (isStudio)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(user.subscriptionStatus.subscriptionLabel,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                    if (!user.isActive)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: const Text('Suspended',
                            style: TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _InfoCard(
            title: 'Profile',
            rows: [
              _InfoRow('Phone', user.phone.isEmpty ? '—' : user.phone),
              _InfoRow('City', user.city ?? '—'),
              if (isStudio) _InfoRow('Studio name', user.studioName ?? '—'),
              _InfoRow('Joined',
                  '${user.joinedAt.day}/${user.joinedAt.month}/${user.joinedAt.year}'),
              _InfoRow('Role', isStudio ? 'Photographer / Studio' : 'Client'),
              _InfoRow('Storage used', formatBytes(user.usedBytes ?? 0)),
              _InfoRow('Account status', user.isActive ? 'Active' : 'Suspended'),
            ],
          ),
          if (isStudio) ...[
            const SizedBox(height: AppSpacing.md),
            _InfoCard(
              title: 'Subscription',
              rows: [
                _InfoRow('Status', user.subscriptionStatus.subscriptionLabel),
                _InfoRow('Plan', _planLabel(user.currentPlan)),
                _InfoRow('Plan started', _dateTimeLabel(user.planStartedAt)),
                _InfoRow(
                  // Label changes based on whether the plan is still live
                  user.subscriptionStatus == 'active' || user.subscriptionStatus == 'trial'
                      ? 'Next billing'
                      : 'Plan expired',
                  _dateTimeLabel(user.planExpiry),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _updating ? null : _toggleSuspend,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                        color: user.isActive ? context.borderColor : AppColors.secondary),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm)),
                  ),
                  child: _updating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          user.isActive ? 'Suspend account' : 'Reactivate account',
                          style: TextStyle(
                              color: user.isActive ? AppColors.error : AppColors.secondary,
                              fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}



class _InfoCard extends StatelessWidget {
  final String title;
  final List<_InfoRow> rows;
  const _InfoCard({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 14, color: context.textPrimary)),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(fontSize: 12.5, color: context.textMuted)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: context.textPrimary)),
          ),
        ],
      ),
    );
  }
}
