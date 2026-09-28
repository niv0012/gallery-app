import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../storage/onboarding_local_store.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/screen_backdrop.dart';
import 'onboarding_page_1.dart';
import 'onboarding_page_2.dart';
import 'onboarding_page_3.dart';
import '../../core/theme/theme_context.dart';

/// Three premium onboarding pages — [OnboardingPage1], [OnboardingPage2]
/// and [OnboardingPage3] — behind a single [PageView], with an animated
/// dash-style page indicator and Skip / Back / Next / Get Started
/// controls per the brief.
///
/// Also owns the "only show once" behavior: both Skip and Get Started
/// mark onboarding as seen via [OnboardingLocalStore] so [SplashScreen]
/// can route straight to Role Selection on every launch after the
/// first one.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 3;

  final _controller = PageController();
  final _store = OnboardingLocalStore();
  int _page = 0;

  void _goNext() {
    if (_page == _pageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
        duration: AppDurations.medium, curve: Curves.easeOutCubic);
  }

  void _goBack() {
    _controller.previousPage(
        duration: AppDurations.medium, curve: Curves.easeOutCubic);
  }

  Future<void> _finish() async {
    await _store.markOnboardingSeen();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.roleSelection);
  }

  Future<void> _skip() async {
    await _store.markOnboardingSeen();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.roleSelection);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pageCount - 1;

    return Scaffold(
      body: ScreenBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(
                      right: AppSpacing.lg, top: AppSpacing.sm),
                  child: TextButton(
                    onPressed: isLast ? null : _skip,
                    child: Text(
                      'Skip',
                      style: TextStyle(
                        color: isLast ? Colors.transparent : context.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: const [
                    OnboardingPage1(),
                    OnboardingPage2(),
                    OnboardingPage3(),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pageCount, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: AppDurations.fast,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 26 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: active ? AppColors.buttonGradient : null,
                      color: active ? null : context.borderColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    if (_page > 0) ...[
                      Expanded(
                        child: GradientButton(
                          label: 'Back',
                          icon: Icons.arrow_back_rounded,
                          outlined: true,
                          onPressed: _goBack,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    Expanded(
                      flex: _page > 0 ? 1 : 1,
                      child: GradientButton(
                        label: isLast ? 'Get Started' : 'Next',
                        icon: isLast ? Icons.arrow_forward_rounded : null,
                        onPressed: _goNext,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
