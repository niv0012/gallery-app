import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/settings_model.dart';
import '../../models/user.dart';
import '../../providers/auth_providers.dart';
import '../../providers/settings_provider.dart';
import '../../services/deep_link_service.dart';
import '../../storage/onboarding_local_store.dart';
import '../../widgets/common/screen_backdrop.dart';

/// Animated splash: logo scales/fades in over the gradient backdrop, the
/// tagline fades in after, then a soft loading dash before auto-navigating
/// onward.
///
/// Also owns the one-time, cold-start App Lock PIN gate: if
/// `settings.securityPinEnabled && settings.requirePinOnLaunch` are both
/// true, [AppRoutes.pinUnlock] is pushed first and only on a correct PIN
/// does navigation continue onward. This screen only runs once per
/// process start, so the PIN is never asked again mid-session.
///
/// Also owns the "stay logged in" check: [authProvider]'s build() has
/// already restored any saved token from disk and is fetching the
/// current user in the background (see auth_providers.dart). This screen
/// awaits that result before deciding where to go, so a still-valid
/// session skips Onboarding/Role Selection/Login entirely and lands
/// straight on the right home screen — using the exact same
/// unverified-email -> incomplete-profile -> role-based-home priority
/// order as `LoginScreen._navigateAfterAuth`, so a restored session and
/// a fresh login always land in the same place.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;
  late final Animation<double> _taglineFade;

  Timer? _splashTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _logoScale = Tween(begin: 0.7, end: 1.0).animate(CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.6, curve: Curves.easeOutBack)));
    _logoFade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.5, curve: Curves.easeOut)));
    _taglineFade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut)));

    _controller.forward();

    _splashTimer = Timer(AppDurations.splash, () async {
      if (!mounted) return;

      // PRIORITY 1: Check if an incoming gallery deep link launched the app!
      // If so, consume it directly to replace SplashScreen with SharedGalleryScreen.
      // Studio Dashboard and Login routing are completely bypassed.
      // onSplashComplete() MUST be called even on this early return so that
      // _isSplashActive is reset to false — without it, any subsequent deep link
      // received while SharedGalleryScreen is open would be silently queued in
      // _pendingInitialUri rather than handled by handleLink().
      final consumedDeepLink = DeepLinkService.instance
          .consumeInitialGalleryLink(Navigator.of(context));
      if (consumedDeepLink) {
        DeepLinkService.instance.onSplashComplete();
        return;
      }

      // PRIORITY 2: Check for forced app updates.
      try {
        final apiClient = ref.read(apiClientProvider);
        final response = await apiClient.get('/config', withAuth: false);
        final minVersionStr = response['min_app_version'] as String?;
        if (minVersionStr != null && minVersionStr.isNotEmpty) {
          final packageInfo = await PackageInfo.fromPlatform();
          final currentVersionStr = '${packageInfo.version}+${packageInfo.buildNumber}';
          
          if (_isUpdateRequired(currentVersionStr, minVersionStr)) {
            if (!mounted) return;
            Navigator.of(context).pushReplacementNamed(AppRoutes.updateRequired);
            return;
          }
        }
      } catch (e) {
        debugPrint('Failed to fetch /config: $e');
        // If config fails (e.g. network error), continue to load the app
      }
      if (!mounted) return;

      // Backend-agnostic check: OnboardingLocalStore owns the only
      // persistence detail here (a Hive-backed flag today, but callers
      // never need to know that). Falls back to showing onboarding if
      // nothing has been persisted yet, or if the check fails.
      final alreadySeenOnboarding =
          await OnboardingLocalStore().hasSeenOnboarding();
      if (!mounted) return;

      // Read persisted settings directly from the store (bypassing the
      // provider's own async load) so this cold-start check is never
      // racing SettingsNotifier.build()'s background load — see
      // settings_provider.dart.
      final settingsData = await ref.read(settingsStoreProvider).load();
      final settings = settingsData != null
          ? SettingsModel.fromJson(settingsData)
          : const SettingsModel();
      if (!mounted) return;

      // Wait for authProvider's build() to finish restoring/validating
      // any saved token (see auth_providers.dart AuthNotifier.build()).
      // A restored, still-valid session means we skip straight past
      // Onboarding/Role Selection/Login — that's the whole point of
      // "Remember me" persisting a token in the first place.
      AppUser? restoredUser;
      try {
        restoredUser = await ref.read(authProvider.future);
      } catch (_) {
        restoredUser = null;
      }
      if (!mounted) return;



      // PRIORITY 1 RE-CHECK: If a deep link arrived while auth restoration
      // or onboarding check was running asynchronously, consume it now to
      // replace SplashScreen directly with SharedGalleryScreen.
      // Same onSplashComplete() call as above — both early-return paths must
      // reset _isSplashActive so subsequent stream deep links are not dropped.
      final consumedDeepLinkAfterAsync = DeepLinkService.instance
          .consumeInitialGalleryLink(Navigator.of(context));
      if (consumedDeepLinkAfterAsync) {
        DeepLinkService.instance.onSplashComplete();
        return;
      }

      final destination = _resolveDestination(
        restoredUser,
        alreadySeenOnboarding: alreadySeenOnboarding,
      );

      if (settings.securityPinEnabled && settings.requirePinOnLaunch) {
        Navigator.of(context).pushReplacementNamed(
          AppRoutes.pinUnlock,
          arguments: PinUnlockArgs(
            correctPin: settings.securityPin,
            destinationRoute: destination.route,
            destinationArguments: destination.arguments,
          ),
        );
        return;
      }

      _navigateToDestination(destination, restoredUser);
    });
  }

  /// A restored session that still needs to verify its email or finish
  /// its profile used to land with a single `pushReplacementNamed` —
  /// leaving [AppRoutes.verificationPending] / [AppRoutes.completeProfile]
  /// with nothing beneath them, so their back button had nowhere to go.
  /// For those two "gate" screens, this instead rebuilds a real stack
  /// (Role Selection -> Login -> gate screen) so back steps through the
  /// screens one at a time, the same as if the user had navigated there
  /// by hand, instead of jumping straight to Login. Any other
  /// destination (onboarding, role selection, or a completed session's
  /// home screen) keeps the original single-replace behavior — those
  /// screens don't show a back arrow in the first place.
  void _navigateToDestination(_ResolvedDestination destination, AppUser? user) {
    final navigator = Navigator.of(context);
    final isGateScreen = user != null &&
        (destination.route == AppRoutes.verificationPending ||
            destination.route == AppRoutes.completeProfile);

    if (!isGateScreen) {
      navigator.pushReplacementNamed(destination.route,
          arguments: destination.arguments);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        DeepLinkService.instance.onSplashComplete();
      });
      return;
    }

    final legacyRole = user.role == AppUserRole.photographer
        ? UserRole.photographer
        : UserRole.client;
    navigator.pushReplacementNamed(AppRoutes.roleSelection);
    navigator.pushNamed(AppRoutes.login, arguments: legacyRole);
    navigator.pushNamed(destination.route, arguments: destination.arguments);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.instance.onSplashComplete();
    });
  }

  /// Same priority order as `LoginScreen._navigateAfterAuth`: a restored
  /// session with an unverified email or incomplete profile still needs
  /// to finish that step, not land straight on home. `null` (no valid
  /// restored session) falls back to onboarding/role-selection exactly
  /// as before this fix.
  ///
  /// Bundles the target route together with whatever `settings.arguments`
  /// that route itself requires per `app_routes.dart`'s `onGenerateRoute`
  /// (e.g. completeProfile needs a `UserRole`, verificationPending needs
  /// a `{email, role}` map) — pushing the route name alone, as an earlier
  /// version of this fix did, left those screens with no role/email and
  /// caused photographer accounts to silently lose their Studio Name
  /// field (widget.role came back null, so `_isPhotographer` was false)
  /// while the backend still rejected the save for missing studio_name.
  _ResolvedDestination _resolveDestination(
    AppUser? user, {
    required bool alreadySeenOnboarding,
  }) {
    if (user == null) {
      return _ResolvedDestination(
        alreadySeenOnboarding ? AppRoutes.roleSelection : AppRoutes.onboarding,
      );
    }

    final legacyRole = user.role == AppUserRole.photographer
        ? UserRole.photographer
        : UserRole.client;

    if (!user.isEmailVerified) {
      return _ResolvedDestination(
        AppRoutes.verificationPending,
        arguments: {'email': user.email, 'role': legacyRole},
      );
    }
    if (!user.hasCompletedProfile) {
      return _ResolvedDestination(AppRoutes.completeProfile,
          arguments: legacyRole);
    }
    return _ResolvedDestination(
      legacyRole == UserRole.photographer
          ? AppRoutes.adminHome
          : AppRoutes.home,
    );
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    _splashTimer = null;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final taglineColor = isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    final trackColor = isDark ? AppColors.darkSurfaceRaised : AppColors.border;

    return Scaffold(
      body: ScreenBackdrop(
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeTransition(
                    opacity: _logoFade,
                    child: ScaleTransition(
                      scale: _logoScale,
                      child: Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          gradient: AppColors.heroGradient,
                          borderRadius: BorderRadius.circular(32),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.4),
                              blurRadius: 40,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.camera_alt_rounded,
                            color: Colors.white, size: 52),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FadeTransition(
                    opacity: _logoFade,
                    child: ShaderMask(
                      shaderCallback: (b) =>
                          AppColors.heroGradient.createShader(b),
                      child: const Text(
                        AppStrings.appName,
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  FadeTransition(
                    opacity: _taglineFade,
                    child: Text(
                      AppStrings.tagline,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: taglineColor,
                          letterSpacing: 0.3),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  FadeTransition(
                    opacity: _taglineFade,
                    child: SizedBox(
                      width: 120,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          minHeight: 4,
                          backgroundColor: trackColor,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
  bool _isUpdateRequired(String current, String minimum) {
    // Format is typically "1.0.0+42"
    List<String> parseVersion(String v) {
      final parts = v.split('+');
      final version = parts[0];
      final build = parts.length > 1 ? parts[1] : '0';
      return [...version.split('.'), build];
    }

    try {
      final currentParts = parseVersion(current);
      final minParts = parseVersion(minimum);
      
      for (var i = 0; i < 4; i++) {
        final currentVal = i < currentParts.length ? int.tryParse(currentParts[i]) ?? 0 : 0;
        final minVal = i < minParts.length ? int.tryParse(minParts[i]) ?? 0 : 0;
        
        if (currentVal < minVal) return true;
        if (currentVal > minVal) return false;
      }
    } catch (_) {
      // If parsing fails, don't block the user
    }
    return false;
  }
}

/// A route name paired with whatever `settings.arguments` that specific
/// route needs once pushed — see `_SplashScreenState._resolveDestination`.
class _ResolvedDestination {
  final String route;
  final Object? arguments;
  const _ResolvedDestination(this.route, {this.arguments});
}
