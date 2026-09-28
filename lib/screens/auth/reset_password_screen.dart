import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/auth_container.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../core/theme/theme_context.dart';

/// Reset Password: a large gradient illustration, a Reset Code field,
/// New Password / Confirm Password fields and a gradient Reset Password
/// button. Mirrors the layout of [ForgotPasswordScreen].
///
/// [token], if provided, prefills the Reset Code field (e.g. a future
/// deep link), but the field is always editable — the app has no
/// deep-link handling today, so [CheckEmailScreen]'s "Enter Reset Code"
/// button is the only real path here, and the user types in the
/// 6-digit code emailed by `POST /auth/forgot-password` themselves.
/// [email] is accepted purely for display/context.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String? email;
  final String? token;
  const ResetPasswordScreen({super.key, this.email, this.token});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // If a token ever does arrive via a real deep link in future, prefill
    // it so the field isn't empty — but the field stays editable either
    // way, since manual entry is the only path that exists today.
    if (widget.token != null) _codeController.text = widget.token!;
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authRepositoryProvider).resetPassword(
            token: _codeController.text.trim(),
            newPassword: _passwordController.text,
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushReplacementNamed(AppRoutes.resetSuccess);
  }

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const CustomAppBar(),
      body: ScreenBackdrop(
        child: SafeArea(
          top: false,
          child: AuthContainer(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: AppSpacing.md),
                  Center(
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        gradient: AppColors.heroGradient,
                        borderRadius: BorderRadius.circular(44),
                        boxShadow: [
                          BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.3),
                              blurRadius: 36,
                              offset: const Offset(0, 16)),
                        ],
                      ),
                      child: const Icon(Icons.password_rounded,
                          color: Colors.white, size: 68),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Reset Password',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text(
                    widget.email == null || widget.email!.isEmpty
                        ? 'Enter the code we emailed you and choose a new password.'
                        : 'Enter the code we sent to\n${widget.email}\nand choose a new password.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: context.textMuted),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (_errorMessage != null) ...[
                    InlineErrorBanner(message: _errorMessage!),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  CustomTextField(
                    label: 'Reset Code',
                    hint: '6-digit code from your email',
                    icon: Icons.pin_outlined,
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    validator: (v) => (v == null || v.trim().length != 6)
                        ? 'Enter the 6-digit code'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  CustomTextField(
                    label: 'New Password',
                    icon: Icons.lock_outline_rounded,
                    obscureText: true,
                    controller: _passwordController,
                    validator: (v) {
                      if (v == null || v.length < 8) {
                        return 'At least 8 characters, including a number';
                      }
                      if (!RegExp(r'[0-9]').hasMatch(v)) {
                        return 'Include at least one number';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  CustomTextField(
                    label: 'Confirm Password',
                    icon: Icons.lock_outline_rounded,
                    obscureText: true,
                    controller: _confirmController,
                    validator: (v) => v != _passwordController.text
                        ? 'Passwords do not match'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  GradientButton(
                      label: 'Reset Password',
                      isLoading: _isLoading,
                      onPressed: _resetPassword),
                  const SizedBox(height: AppSpacing.lg),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context)
                          .pushNamedAndRemoveUntil(
                              AppRoutes.login, (r) => false),
                      child: const Text('Back to Login',
                          style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
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
