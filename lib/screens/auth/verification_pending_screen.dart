import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/app_popup.dart';
import '../../widgets/common/auth_container.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// Blocked-state counterpart to `email_verification_screen.dart`. That
/// screen is the initial "we just sent it" confirmation right after
/// registering; this one is what a user lands on if they try to proceed
/// before actually confirming — e.g. reopening the app mid-flow, or
/// tapping ahead from a stale link. Same badge/layout language, but a
/// pending clock icon instead of the success checkmark, and copy framed
/// as a requirement to clear rather than a thing that already happened.
///
/// `_resend()` calls the real `POST /auth/send-verification-email`,
/// which requires the Bearer token set by login/register — this screen
/// should only ever be reached with a session already in place.
class VerificationPendingScreen extends ConsumerStatefulWidget {
  final String email;
  final UserRole? role;
  const VerificationPendingScreen({super.key, required this.email, this.role});

  @override
  ConsumerState<VerificationPendingScreen> createState() =>
      _VerificationPendingScreenState();
}

class _VerificationPendingScreenState
    extends ConsumerState<VerificationPendingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: AppDurations.medium)
        ..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  bool _resending = false;
  bool _checking = false;

  Future<void> _checkVerifiedAndContinue() async {
    setState(() => _checking = true);
    try {
      final user = await ref.read(authRepositoryProvider).getMe();
      if (!mounted) return;
      if (user.isEmailVerified) {
        Navigator.of(context)
            .pushNamed(AppRoutes.completeProfile, arguments: widget.role);
      } else {
        await AppPopup.show(
          context,
          title: "Not Verified Yet",
          message:
              "You haven't verified your email yet. Check your inbox and tap the link, then try again.",
          isError: true,
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      await AppPopup.show(context,
          title: "Something Went Wrong", message: e.message, isError: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      final message =
          await ref.read(authRepositoryProvider).sendVerificationEmail();
      if (!mounted) return;
      await AppPopup.show(context, title: "Email Sent", message: message);
    } on ApiException catch (e) {
      if (!mounted) return;
      await AppPopup.show(context,
          title: "Something Went Wrong", message: e.message, isError: true);
    } finally {
      if (mounted) setState(() => _resending = false);
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
      extendBodyBehindAppBar: true,
      appBar: const CustomAppBar(),
      body: ScreenBackdrop(
        child: SafeArea(
          top: true,
          child: AuthContainer(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl, vertical: AppSpacing.xl),
            mainAxisAlignment: MainAxisAlignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                            color: AppColors.accent.withValues(alpha: 0.3),
                            blurRadius: 36,
                            offset: const Offset(0, 16)),
                      ],
                    ),
                    child: const Icon(Icons.watch_later_rounded,
                        color: Colors.white, size: 58),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Verify your email to continue',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  widget.email.isEmpty
                      ? 'We\'re still waiting on you to confirm your email before you can continue.'
                      : 'We\'re still waiting on you to confirm\n${widget.email}\nbefore you can continue.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.xxl),
                GradientButton(
                  label: 'I\'ve Verified — Continue',
                  isLoading: _checking,
                  onPressed: _checking ? null : _checkVerifiedAndContinue,
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
                      : const Text('Resend Email',
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
