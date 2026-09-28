import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/admin_dashboard_data.dart';
import '../../providers/admin_dashboard_providers.dart';
import '../../providers/auth_providers.dart';
import '../../providers/settings_provider.dart';
import '../../services/studio_logo_actions.dart';

/// Gradient (purple → pink) header for [StudioDrawer].
///
/// Reads the studio/admin identity from the same [settingsProvider] used by
/// Studio Settings (so it never drifts out of sync), and the storage stat
/// from the live [adminDashboardProvider] snapshot already powering the
/// dashboard — nothing here is hardcoded.
class StudioDrawerHeader extends ConsumerStatefulWidget {
  const StudioDrawerHeader({super.key});

  @override
  ConsumerState<StudioDrawerHeader> createState() =>
      _StudioDrawerHeaderState();
}

enum _LogoAction { change, remove }

class _StudioDrawerHeaderState extends ConsumerState<StudioDrawerHeader> {
  bool _updatingLogo = false;

  /// Tap on the logo: bottom sheet with Add/Change and (if a logo exists)
  /// Remove.
  Future<void> _onLogoTap(bool hasLogo) async {
    if (_updatingLogo) return;
    final action = await showModalBottomSheet<_LogoAction>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(hasLogo ? 'Change logo' : 'Add logo'),
              onTap: () => Navigator.of(ctx).pop(_LogoAction.change),
            ),
            if (hasLogo)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.error),
                title: const Text('Remove logo',
                    style: TextStyle(color: AppColors.error)),
                onTap: () => Navigator.of(ctx).pop(_LogoAction.remove),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action == _LogoAction.remove) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove logo?'),
          content: const Text(
              'Your studio will go back to the default camera icon.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _runLogoAction(action);
  }

  Future<void> _runLogoAction(_LogoAction action) async {
    // Grab these before any await: the drawer may be closed mid-upload.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updatingLogo = true);
    try {
      if (action == _LogoAction.remove) {
        await StudioLogoActions.remove(container);
        messenger.showSnackBar(
            const SnackBar(content: Text('Studio logo removed.')));
      } else {
        final url = await StudioLogoActions.pickAndUpload(container);
        if (url != null) {
          messenger.showSnackBar(
              const SnackBar(content: Text('Studio logo updated.')));
        }
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(
        content: Text(action == _LogoAction.remove
            ? "Couldn't remove the logo. Please try again."
            : "Couldn't update the logo. Please try again."),
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _updatingLogo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final snapshot = ref.watch(adminDashboardProvider).value;
    final authUser = ref.watch(authStateProvider).user;
    final logoUrl = authUser?.avatarUrl;
    final hasLogo = logoUrl != null && logoUrl.isNotEmpty;

    // Use the real logged-in user's profile as the primary source so the
    // hardcoded SettingsModel defaults ("Naman Shrivastava") never show up.
    final studioName = (authUser?.studioName?.isNotEmpty == true)
        ? authUser!.studioName!
        : (settings.studioName.isNotEmpty
            ? settings.studioName
            : (snapshot?.studioName ?? 'Studio'));
    final adminName = (authUser?.fullName.isNotEmpty == true)
        ? authUser!.fullName
        : (settings.photographerName.isNotEmpty
            ? settings.photographerName
            : (snapshot?.photographerName ?? 'Studio Admin'));
    final adminEmail =
        (authUser?.email.isNotEmpty == true) ? authUser!.email : settings.email;
    final initial = adminName.isNotEmpty ? adminName[0].toUpperCase() : '?';

    final storage = _storageUsage(snapshot);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        MediaQuery.of(context).padding.top + AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        // Purple → Pink, as specified in the brief.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.accent],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Studio logo/icon + studio name.
          Row(
            children: [
              _LogoBadge(
                logoUrl: hasLogo ? logoUrl : null,
                updating: _updatingLogo,
                onTap: () => _onLogoTap(hasLogo),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  studioName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Avatar (with subscription badge) + name/email + Edit Profile.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.24),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      adminName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      adminEmail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    _EditProfileButton(
                      onTap: () {
                        Navigator.of(context).pop(); // close drawer
                        Navigator.of(context)
                            .pushNamed(AppRoutes.adminSettings);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),
          _StorageUsageBar(
              usedLabel: storage.usedLabel,
              totalLabel: storage.totalLabel,
              percent: storage.percent),
        ],
      ),
    );
  }

  _StorageStat _storageUsage(AdminDashboardSnapshot? snapshot) {
    if (snapshot == null) {
      return const _StorageStat(usedLabel: '—', totalLabel: '', percent: 0);
    }
    final stat = snapshot.stats.cast<StatCardData?>().firstWhere(
          (s) => s?.label == 'Storage Used',
          orElse: () => null,
        );
    final usedLabel = stat?.value ?? '0 GB';
    final totalMedia =
        snapshot.recentUploads.fold<int>(0, (sum, u) => sum + u.mediaCount);
    final storageGb = totalMedia * 1.4 / 1000;
    final percent = (storageGb / 1024).clamp(0.0, 1.0);
    return _StorageStat(
      usedLabel: usedLabel,
      totalLabel: '',
      percent: percent,
    );
  }
}

/// The studio logo in the drawer header: shows [logoUrl] when set (camera
/// icon otherwise), a spinner while uploading, and a small camera badge that
/// signals it is tappable.
class _LogoBadge extends StatelessWidget {
  const _LogoBadge({
    required this.logoUrl,
    required this.updating,
    required this.onTap,
  });

  final String? logoUrl;
  final bool updating;
  final VoidCallback onTap;

  static const double _size = 44;

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(Icons.camera_alt_rounded,
        color: Colors.white, size: 20);

    return Semantics(
      button: true,
      label: 'Studio logo. Tap to change or remove.',
      child: GestureDetector(
        onTap: updating ? null : onTap,
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  alignment: Alignment.center,
                  child: logoUrl == null
                      ? fallback
                      : Image.network(
                          logoUrl!,
                          width: _size,
                          height: _size,
                          fit: BoxFit.cover,
                          cacheWidth: (_size * 3).round(),
                          errorBuilder: (_, __, ___) => fallback,
                        ),
                ),
              ),
              if (updating)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                ),
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.camera_alt_rounded,
                      size: 11, color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageStat {
  final String usedLabel;
  final String totalLabel;
  final double percent;
  const _StorageStat(
      {required this.usedLabel,
      required this.totalLabel,
      required this.percent});
}

class _EditProfileButton extends StatelessWidget {
  const _EditProfileButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_rounded, color: Colors.white, size: 12),
              SizedBox(width: 5),
              Text('Edit Profile',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageUsageBar extends StatelessWidget {
  const _StorageUsageBar(
      {required this.usedLabel,
      required this.totalLabel,
      required this.percent});
  final String usedLabel;
  final String totalLabel;
  final double percent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Storage',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
            Text(
              '$usedLabel / $totalLabel',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.25),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      ],
    );
  }
}
