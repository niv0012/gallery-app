import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// Small reusable success screen shown after a password reset completes:
/// a scale-in green checkmark badge (mirrors [EmailVerificationScreen]'s
/// animation), a headline, a short subtitle and a single Back to Login
/// gradient button that clears the nav stack back to [AppRoutes.login].
class ResetSuccessScreen extends StatefulWidget {
  const ResetSuccessScreen({super.key});

  @override
  State<ResetSuccessScreen> createState() => _ResetSuccessScreenState();
}

class _ResetSuccessScreenState extends State<ResetSuccessScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: AppDurations.medium)
        ..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

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
                      color: AppColors.success,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: AppColors.success.withValues(alpha: 0.3),
                            blurRadius: 36,
                            offset: const Offset(0, 16)),
                      ],
                    ),
                    child: const Icon(Icons.check_rounded,
                        color: Colors.white, size: 68),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Password Reset!',
                    style: Theme.of(context).textTheme.headlineLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  'Your password has been changed successfully.\nYou can now sign in with your new password.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.xxl),
                GradientButton(
                  label: 'Back to Login',
                  onPressed: () => Navigator.of(context)
                      .pushNamedAndRemoveUntil(
                          AppRoutes.login, (route) => false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
