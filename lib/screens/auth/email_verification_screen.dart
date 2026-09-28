import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// Confirms an email was sent with a scale-in success badge, offers
/// Resend Email (with a short cooldown feel via loading state) and a
/// Continue button into Complete Profile.
class EmailVerificationScreen extends StatefulWidget {
  final String email;
  final UserRole? role;
  const EmailVerificationScreen({super.key, required this.email, this.role});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: AppDurations.medium)
        ..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  bool _resending = false;

  Future<void> _resend() async {
    setState(() => _resending = true);
    await Future.delayed(
        const Duration(milliseconds: 900)); // dummy navigation only
    if (!mounted) return;
    setState(() => _resending = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email resent.')));
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
                    child: const Icon(Icons.mark_email_read_rounded,
                        color: Colors.white, size: 58),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Verify Your Email',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  widget.email.isEmpty
                      ? 'We\'ve sent a verification link to your email.'
                      : 'We\'ve sent a verification link to\n${widget.email}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.xxl),
                GradientButton(
                  label: 'Continue',
                  onPressed: () => Navigator.of(context).pushNamed(
                      AppRoutes.completeProfile,
                      arguments: widget.role ?? UserRole.client),
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
