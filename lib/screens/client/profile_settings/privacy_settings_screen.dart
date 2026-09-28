import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/settings_model.dart';
import '../../../providers/auth_providers.dart';
import '../../../providers/settings_provider.dart';
import '../../../providers/user_providers.dart';
import '../../../widgets/common/app_toast.dart';
import '../../../widgets/common/custom_app_bar.dart';
import '../../../core/theme/theme_context.dart';

class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() =>
      _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen> {
  // True while a PATCH /users/me for allow_downloads is in flight — keeps
  // the toggle disabled so a second tap can't race the first.
  bool _savingDownloads = false;

  // Same, for the "Account Privacy" toggle's private_profile PATCH.
  bool _savingPrivateProfile = false;

  /// Persists the "Download Permissions" toggle server-side
  /// (`User.allow_downloads`, PATCH /users/me) and pushes the returned
  /// user straight into [authProvider] so it — and every other screen
  /// reading it — reflects the change immediately, matching
  /// [EditProfileScreen]'s save flow. Server-persisted (not
  /// [settingsProvider]/Hive) so it survives reinstalls and is visible
  /// to the backend, same as `push_notifications_enabled`.
  Future<void> _handleAllowDownloadsChanged(bool value) async {
    setState(() => _savingDownloads = true);
    try {
      final updated = await ref
          .read(userRepositoryProvider)
          .updateProfile(allowDownloads: value);
      ref.read(authProvider.notifier).setUser(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.show(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _savingDownloads = false);
    }
  }

  /// Persists the "Account Privacy" toggle server-side
  /// (`User.private_profile`, PATCH /users/me), same pattern as
  /// [_handleAllowDownloadsChanged] above. Previously this only wrote to
  /// [settingsProvider]/Hive (device-local) even though the backend has
  /// had a real `private_profile` column since the privacy-fields
  /// migration — so the toggle looked like it worked but never actually
  /// changed anything the backend or other users could see.
  Future<void> _handlePrivateProfileChanged(bool value) async {
    setState(() => _savingPrivateProfile = true);
    try {
      final updated = await ref
          .read(userRepositoryProvider)
          .updateProfile(privateProfile: value);
      ref.read(authProvider.notifier).setUser(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.show(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _savingPrivateProfile = false);
    }
  }

  /// Same App Lock PIN setup/change/disable flow as the studio side
  /// (`AdminSettingsScreen._setupSecurityPin`) — both roles share the
  /// same [SettingsModel]/[settingsProvider], so a PIN set here is
  /// enforced by the same [SplashScreen] launch check either way.
  void _setupSecurityPin(SettingsModel settings) {
    showDialog(
      context: context,
      builder: (context) =>
          _SetupSecurityPinDialog(settings: settings, ref: ref),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final allowDownloads =
        ref.watch(authProvider).valueOrNull?.allowDownloads ?? true;
    final privateProfile =
        ref.watch(authProvider).valueOrNull?.privateProfile ?? false;

    return Scaffold(
      appBar: const CustomAppBar(title: 'Privacy & Security', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.lg),
          children: [
            _ToggleTile(
              icon: Icons.lock_outline_rounded,
              title: 'Account Privacy',
              value: privateProfile,
              disabled: _savingPrivateProfile,
              onChanged: _handlePrivateProfileChanged,
            ),
            SizedBox(height: AppSpacing.md),
            _ToggleTile(
              icon: Icons.download_for_offline_rounded,
              title: 'Download Permissions',
              value: allowDownloads,
              disabled: _savingDownloads,
              onChanged: _handleAllowDownloadsChanged,
            ),
            SizedBox(height: AppSpacing.md),
            _TapTile(
              icon: Icons.pin_rounded,
              title: 'App Lock',
              subtitle: !settings.securityPinEnabled
                  ? 'PIN Disabled'
                  : settings.requirePinOnLaunch
                      ? 'PIN required at launch'
                      : 'PIN set — not required at launch yet',
              onTap: () => _setupSecurityPin(settings),
            ),
            if (settings.securityPinEnabled) ...[
              SizedBox(height: AppSpacing.md),
              _ToggleTile(
                icon: Icons.fingerprint_rounded,
                title: 'Require PIN on Launch',
                value: settings.requirePinOnLaunch,
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .updateSettings(settings.copyWith(requirePinOnLaunch: v)),
              ),
            ],
            SizedBox(height: AppSpacing.lg),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pushNamed(AppRoutes.deleteAccount);
              },
              icon: Icon(Icons.delete_forever_rounded,
                  color: AppColors.error),
              label: Text(
                'Delete Account',
                style: TextStyle(
                    color: AppColors.error, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  side: const BorderSide(color: AppColors.error),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool disabled;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        border: Border.all(color: context.borderColor),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
              border: Border.all(color: context.borderColor),
            ),
            child: Icon(icon, color: AppColors.primary),
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: disabled ? null : onChanged,
          ),
        ],
      ),
    );
  }
}

/// Tappable counterpart to [_ToggleTile] for rows that open a dialog or
/// another screen instead of flipping a switch (here: App Lock, which
/// opens [_SetupSecurityPinDialog]). Mirrors the same card look so it
/// sits visually consistent with the toggle rows above it.
class _TapTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TapTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkSurface
          : Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            border: Border.all(color: context.borderColor),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                  border: Border.all(color: context.borderColor),
                ),
                child: Icon(icon, color: AppColors.primary),
              ),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Set / change / disable the App Lock PIN. Identical flow and copy to
/// the studio side's `_SetupSecurityPinDialog`
/// (`screens/admin/admin_settings_screen.dart`) — kept as a separate
/// private class here (rather than a shared import) so this screen's
/// file stays self-contained, same as the studio screen's own dialog.
class _SetupSecurityPinDialog extends StatefulWidget {
  final SettingsModel settings;
  final WidgetRef ref;

  const _SetupSecurityPinDialog({required this.settings, required this.ref});

  @override
  State<_SetupSecurityPinDialog> createState() =>
      _SetupSecurityPinDialogState();
}

class _SetupSecurityPinDialogState extends State<_SetupSecurityPinDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pinCtrl;

  // Only toggles visibility of what's being typed into the field right
  // now — the previously-saved PIN itself is never read back/displayed
  // here, so this can't be used to recover a forgotten PIN.
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _pinCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
          widget.settings.securityPinEnabled
              ? 'Change Security PIN'
              : 'Setup App Lock PIN',
          style: TextStyle(
              color: isDark ? AppColors.textOnDark : AppColors.text,
              fontWeight: FontWeight.bold)),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The field below always starts blank — the previously-saved
            // PIN is never read back/displayed (see note on _obscure
            // above) — so without this line there's no visual cue that a
            // PIN already exists until the user taps in and sees the
            // '••••' hint.
            if (widget.settings.securityPinEnabled) ...[
              Text(
                'A PIN is already set. Enter a new 4-digit PIN below to change it.',
                style: TextStyle(
                  color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                  fontSize: 13,
                ),
              ),
              SizedBox(height: 12),
            ],
            TextFormField(
              controller: _pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: _obscure,
              maxLength: 4,
              // Explicitly opt out of platform autofill — Android/iOS
              // treat any obscured numeric field as a password field and
              // will overlay a saved-credential suggestion (rendered as
              // dots) on top of it. That overlay isn't real input (the
              // counter stays 0/4 until something is actually typed) and
              // isn't the app's stored PIN, but it has no business
              // appearing on this field at all.
              autofillHints: const <String>[],
              enableSuggestions: false,
              autocorrect: false,
              // The default maxLength counter wasn't refreshing live as
              // digits were entered (stuck at 0/4 while the field itself
              // updated fine), so drive it explicitly off the controller
              // instead of relying on the framework's own listener.
              onChanged: (_) => setState(() {}),
              buildCounter: (context,
                  {required currentLength, required isFocused, maxLength}) {
                return Text(
                  '${_pinCtrl.text.length}/$maxLength',
                  style: TextStyle(
                    color:
                        isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                    fontSize: 12,
                  ),
                );
              },
              decoration: InputDecoration(
                labelText: '4-Digit PIN',
                hintText: '••••',
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().length != 4) {
                  return 'PIN must be 4 digits';
                }
                if (int.tryParse(v) == null) {
                  return 'PIN must contain numbers only';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        if (widget.settings.securityPinEnabled)
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              final updated = widget.settings.copyWith(
                securityPinEnabled: false,
                securityPin: '',
                requirePinOnLaunch: false,
              );
              navigator.pop();
              await widget.ref
                  .read(settingsProvider.notifier)
                  .updateSettings(updated);
              messenger.showSnackBar(
                const SnackBar(content: Text('App Lock PIN disabled')),
              );
            },
            child: Text('Disable',
                style: TextStyle(
                    color: AppColors.error, fontWeight: FontWeight.w700)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style: TextStyle(
                  color:
                      isDark ? AppColors.subtitleOnDark : AppColors.subtitle)),
        ),
        ElevatedButton(
          onPressed: () async {
            if (_formKey.currentState!.validate()) {
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              final updated = widget.settings.copyWith(
                securityPinEnabled: true,
                securityPin: _pinCtrl.text.trim(),
                // First-time setup should actually lock the app on next
                // launch, not just save a PIN that's never enforced.
                // Preserve the user's existing choice when they're just
                // changing an already-active PIN.
                requirePinOnLaunch: widget.settings.securityPinEnabled
                    ? widget.settings.requirePinOnLaunch
                    : true,
              );
              navigator.pop();
              await widget.ref
                  .read(settingsProvider.notifier)
                  .updateSettings(updated);
              messenger.showSnackBar(
                const SnackBar(content: Text('App Lock PIN set successfully')),
              );
            }
          },
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
          child: Text(widget.settings.securityPinEnabled ? 'Update' : 'Enable',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
