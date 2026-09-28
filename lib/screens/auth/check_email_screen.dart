import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// Confirms a password-reset email was sent: a scale-in envelope badge,
/// "check your inbox" copy naming the destination email, a cooldown-style
/// Resend text button, and an Open Mail App gradient button that launches
/// the device's default mail app via `url_launcher` (a bare `mailto:`
/// URI, so nothing is prefilled — it just opens the app/picker). Mirrors
/// [EmailVerificationScreen].
///
/// `_resend()` calls the real `POST /auth/forgot-password` again for
/// [email] — same generic-success endpoint [ForgotPasswordScreen] used
/// to get here.
class CheckEmailScreen extends ConsumerStatefulWidget {
  final String email;
  const CheckEmailScreen({super.key, required this.email});

  @override
  ConsumerState<CheckEmailScreen> createState() => _CheckEmailScreenState();
}

class _CheckEmailScreenState extends ConsumerState<CheckEmailScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: AppDurations.medium)
        ..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  bool _resending = false;

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      final message =
          await ref.read(authRepositoryProvider).forgotPassword(widget.email);
      if (!mounted) return;
      AppToast.show(context, message);
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.show(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _openMailApp() async {
    // A bare "mailto:" URI (no recipient/subject) is the standard
    // cross-platform way to hand off to whatever mail app/picker the
    // device already has — there's no single universal "open inbox"
    // intent across iOS/Android.
    final uri = Uri(scheme: 'mailto');
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        AppToast.show(context, 'No mail app found on this device',
            isError: true);
      }
    } catch (_) {
      if (mounted) {
        AppToast.show(context, 'No mail app found on this device',
            isError: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const CustomAppBar(),
      body: ScreenBackdrop(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _scale,
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      gradient: AppColors.heroGradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: AppColors.success.withValues(alpha: 0.3),
                            blurRadius: 36,
                            offset: const Offset(0, 16)),
                      ],
                    ),
                    child: const Icon(Icons.mark_email_unread_rounded,
                        color: Colors.white, size: 58),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Check Your Inbox',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  widget.email.isEmpty
                      ? 'We\'ve sent a reset link to your email.'
                      : 'We\'ve sent a reset link to\n${widget.email}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.xl),
                GradientButton(label: 'Open Mail App', onPressed: _openMailApp),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.resetPassword,
                    arguments: {'email': widget.email, 'token': null},
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    side: const BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text(
                    'Enter Reset Code',
                    style: TextStyle(
                        color: AppColors.primary, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: _resending ? null : _resend,
                  child: _resending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.primary))
                      : const Text('Resend',
                          style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamedAndRemoveUntil(AppRoutes.login, (r) => false),
                  child: const Text('Back to Login',
                      style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
