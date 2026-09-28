import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';
import '../../providers/user_providers.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/cards/glass_card.dart';
import '../../widgets/common/app_popup.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../core/theme/theme_context.dart';

/// Delete Account screen (Task 10): asks for the account password, a
/// tick-box acknowledging the action is permanent, then a second
/// confirm-dialog "are you sure" before actually calling
/// `DELETE /users/me` through [UserRepository].
///
/// On success, the backend has already soft-deleted the account and
/// revoked its token server-side (`is_deleted` is checked by every
/// future request via `get_current_user`); this screen finishes the job
/// locally by calling `AuthNotifier.logout()` (clears the persisted
/// token + resets in-app state) and dropping the user back at Role
/// Selection with the whole navigation stack cleared, so there's no way
/// to swipe/pop back into a screen that belonged to the now-deleted
/// account.
///
/// Standalone screen only, per the same convention [EditProfileScreen]
/// (Task 7) established â€” nothing navigates here yet; `ProfileScreen`'s
/// menu is still the dummy placeholder described there.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();

  bool _acknowledged = false;
  bool _isDeleting = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleDeletePressed(bool isLocal) async {
    if (isLocal && !_formKey.currentState!.validate()) return;
    if (!_acknowledged) {
      await AppPopup.show(
        context,
        title: 'One More Thing',
        message:
            'Please confirm you understand this action is permanent before continuing.',
        isError: true,
      );
      return;
    }

    final confirmed = await _showConfirmDialog();
    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    try {
      await ref.read(userRepositoryProvider).deleteAccount(
            password: isLocal ? _passwordController.text : null,
          );
      await ref.read(authProvider.notifier).logout();

      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(AppRoutes.roleSelection, (route) => false);
    } on ApiException catch (e) {
      if (!mounted) return;
      await AppPopup.show(context,
          title: 'Couldn\'t Delete Account', message: e.message, isError: true);
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<bool?> _showConfirmDialog() {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Container(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.lg),
          decoration: BoxDecoration(
            color: (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurface : AppColors.surface),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 12)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    AppColors.error.withValues(alpha: 0.85),
                    AppColors.error
                  ]),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.delete_forever_rounded,
                    color: Colors.white, size: 30),
              ),
              SizedBox(height: AppSpacing.md),
              Text('Delete Your Account?',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              SizedBox(height: AppSpacing.sm),
              Text(
                'This is permanent. You\'ll be signed out immediately and won\'t be able to sign back in with this account.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.4),
              ),
              SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: GradientButton(
                      label: 'Cancel',
                      outlined: true,
                      height: 52,
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                    ),
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: GradientButton(
                      label: 'Delete',
                      height: 52,
                      gradient: LinearGradient(colors: [
                        AppColors.error.withValues(alpha: 0.85),
                        AppColors.error
                      ]),
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).valueOrNull;
    final isLocal = user?.authProvider == 'local';

    return Scaffold(
      appBar: const CustomAppBar(title: 'Delete Account'),
      body: ScreenBackdrop(
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GlassCard(
                        fillColor: AppColors.error.withValues(alpha: 0.08),
                        border: Border.all(
                            color: AppColors.error.withValues(alpha: 0.25)),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: AppColors.error, size: 22),
                            SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Text(
                                'Deleting your account is permanent. Your profile will no longer be accessible, '
                                'and you won\'t be able to sign back in with this email.',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: context.textPrimary.withValues(alpha: 0.85),
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isLocal) ...[
                        SizedBox(height: AppSpacing.xl),
                        Text('Confirm Your Password',
                            style: Theme.of(context).textTheme.titleLarge),
                        SizedBox(height: AppSpacing.sm),
                        Text(
                          'For your security, enter your password to continue.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        SizedBox(height: AppSpacing.md),
                        CustomTextField(
                          label: 'Password',
                          icon: Icons.lock_outline_rounded,
                          obscureText: true,
                          controller: _passwordController,
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Enter your password to continue'
                              : null,
                        ),
                      ],
                      SizedBox(height: AppSpacing.lg),
                      InkWell(
                        onTap: () =>
                            setState(() => _acknowledged = !_acknowledged),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 22,
                              width: 22,
                              child: Checkbox(
                                value: _acknowledged,
                                activeColor: AppColors.error,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6)),
                                onChanged: (v) =>
                                    setState(() => _acknowledged = v ?? false),
                              ),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(top: 3),
                                child: Text(
                                  'I understand this action is permanent and cannot be undone.',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: AppSpacing.xl),
                      GradientButton(
                        label: 'Delete My Account',
                        icon: Icons.delete_forever_rounded,
                        isLoading: _isDeleting,
                        gradient: LinearGradient(colors: [
                          AppColors.error.withValues(alpha: 0.85),
                          AppColors.error
                        ]),
                        onPressed: _isDeleting
                            ? null
                            : () => _handleDeletePressed(isLocal),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
