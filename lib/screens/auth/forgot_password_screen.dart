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

/// Forgot Password: a large gradient illustration, an email field and a
/// gradient Send Reset Link button, with a Back to Login link.
///
/// On submit, calls the real `POST /auth/forgot-password` (via
/// [AuthRepository.forgotPassword]) and, on success, pushes
/// [AppRoutes.checkEmail] — mirroring [CheckEmailScreen]'s own Resend
/// button, which hits the same endpoint.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _sendResetLink() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    try {
      await ref.read(authRepositoryProvider).forgotPassword(email);
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
    Navigator.of(context).pushNamed(AppRoutes.checkEmail, arguments: email);
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const CustomAppBar(),
      body: ScreenBackdrop(
        child: SafeArea(
          top: true,
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
                      child: const Icon(Icons.lock_reset_rounded,
                          color: Colors.white, size: 68),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Forgot Password?',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text(
                    'No worries, enter your email and we\'ll send you a reset link.',
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
                    label: 'Email',
                    icon: Icons.mail_outline_rounded,
                    keyboardType: TextInputType.emailAddress,
                    controller: _emailController,
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  GradientButton(
                      label: 'Send Reset Link',
                      isLoading: _isLoading,
                      onPressed: _sendResetLink),
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
