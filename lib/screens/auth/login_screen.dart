import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/user.dart';
import '../../providers/auth_providers.dart';
import '../../services/social_auth_service.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/buttons/social_button.dart';
import '../../widgets/common/auth_container.dart';
import '../../widgets/common/app_popup.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/inline_error_banner.dart';
import '../../widgets/common/logo_widget.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../super_admin/super_admin_dashboard_screen.dart';
import '../../core/api/admin_api_client.dart';
import 'role_selection_screen.dart';
import '../../core/theme/theme_context.dart';

/// Floating login layout (no big white card) — logo + heading up top,
/// fields and gradient Sign In button floating over the blurred backdrop,
/// then a divider with social buttons and a Create Account link.
///
/// On success, routing priority is: unverified email always wins first
/// (→ [AppRoutes.verificationPending]), then an incomplete profile
/// (→ [AppRoutes.completeProfile]), and only once both of those are
/// satisfied does role decide the final home
/// ([AppRoutes.adminHome] for photographers, [AppRoutes.home] for
/// clients). See [_navigateAfterAuth] for the exact order — reused
/// as-is by `splash_screen.dart`'s session bootstrap.
class LoginScreen extends ConsumerStatefulWidget {
  final UserRole? role;
  const LoginScreen({super.key, this.role});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _rememberMe = true;
  bool _isLoading = false;
  String? _errorMessage;

  /// Which social button (if any) is mid-flow — 'google' | 'apple' |
  /// null. A String (not a shared bool) so tapping Google doesn't also
  /// spin the Apple button, and vice versa.
  String? _socialLoadingProvider;

  late final AnimationController _shakeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final Animation<double> _shakeAnimation = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 10.0, end: -6.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -6.0, end: 6.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 6.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.linear));

  @override
  void initState() {
    super.initState();
  }



  Future<void> _handleSignIn() async {
    if (_socialLoadingProvider != null) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authProvider.notifier).login(
            _emailController.text.trim(),
            _passwordController.text,
            role: widget.role == null
                ? null
                : (widget.role == UserRole.photographer
                    ? AppUserRole.photographer
                    : AppUserRole.client),
            rememberMe: _rememberMe,
          );
    } on ApiException catch (e) {
      debugPrint(
          '[Login] ApiException — status: ${e.statusCode}, message: ${e.message}');
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (e.statusCode == 401 || e.statusCode == 400 || e.statusCode == 0) {
        // Fallback: Try Super Admin login before showing error
        try {
          await AdminApiClient.instance.login(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SuperAdminDashboardScreen()),
          );
          return; // Stop the regular error flow!
        } on AdminApiException catch (adminErr) {
          if (!mounted) return;
          // If Supabase says "Invalid login credentials", we'll just fall through to the FastAPI generic error.
          // But if it says "This account is not a Super Admin." (meaning the UUIDs don't match), we MUST show it!
          if (adminErr.statusCode == 403) {
            setState(() => _errorMessage = adminErr.message);
            _shakeController.forward(from: 0);
            return;
          }
        } catch (_) {
          // If it fails for another reason, fall through to show the original client-login error
        }

        if (e.statusCode == 0) {
          await AppPopup.show(context,
              title: 'Something Went Wrong', message: e.message, isError: true);
          return;
        }

        // 401 = wrong credentials; 400 = this email is registered under
        // both a Client and a Studio account and widget.role wasn't
        // enough to disambiguate (e.g. Login reached without a
        // preselected role) — same inline-banner treatment either way.
        setState(() => _errorMessage = _friendlyLoginError(e));
        _shakeController.forward(from: 0);
        return;
      }
      await AppPopup.show(context,
          title: 'Something Went Wrong', message: e.message, isError: true);
      return;
    } catch (e, stack) {
      // Anything that isn't an ApiException (e.g. a response-parsing
      // error) must still clear _isLoading — otherwise the Sign In
      // button spins forever with no error shown at all.
      debugPrint('[Login] Unexpected error: $e\n$stack');
      if (!mounted) return;
      setState(() => _isLoading = false);
      await AppPopup.show(
        context,
        title: 'Something Went Wrong',
        message: 'An unexpected error occurred: ${e.toString()}',
        isError: true,
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    final user = ref.read(authProvider).valueOrNull;
    if (user == null) return;

    _navigateAfterAuth(user);
  }

  /// Maps a backend [ApiException] from the login endpoint into a clear,
  /// user-friendly message shown in the inline error banner.
  ///
  /// The backend sends the reason in [ApiException.message] (FastAPI
  /// `detail` field). We match against known backend strings first; if
  /// nothing matches, we fall back to the raw backend message so nothing
  /// is hidden from the user.
  String _friendlyLoginError(ApiException e) {
    final code = e.statusCode;
    final msg = e.message.toLowerCase();

    debugPrint('[Login] Mapping error — status: $code, raw: ${e.message}');

    // ── Backend-reported credential errors (401 / 400) ──────────────────
    if (msg.contains('not found') ||
        msg.contains('no account') ||
        msg.contains('does not exist')) {
      return 'No account found with this email.';
    }
    if (msg.contains('incorrect password') ||
        msg.contains('wrong password') ||
        msg.contains('invalid password')) {
      return 'Incorrect password.';
    }
    if (msg.contains('invalid credential') ||
        msg.contains('invalid email or password')) {
      return 'Invalid email or password.';
    }
    if (msg.contains('invalid email') || msg.contains('not a valid email')) {
      return 'Please enter a valid email address.';
    }
    if (msg.contains('disabled') ||
        msg.contains('suspended') ||
        msg.contains('banned')) {
      return 'This account has been disabled. Please contact support.';
    }
    if (msg.contains('too many') ||
        msg.contains('rate limit') ||
        msg.contains('throttl')) {
      return 'Too many login attempts. Please try again later.';
    }
    if (msg.contains('network') ||
        msg.contains('connection') ||
        msg.contains('timeout')) {
      return 'Network error. Please check your internet connection.';
    }
    if (msg.contains('not allowed') || msg.contains('not enabled')) {
      return 'Email/password sign-in is not enabled. Please use a different method.';
    }

    // ── Unknown / unrecognised backend error ─────────────────────────────
    // Show the raw message so the user and developer can see exactly
    // what the backend returned — never hide it behind a generic string.
    return e.message.isNotEmpty
        ? e.message
        : 'Login failed (error ${e.statusCode}). Please try again.';
  }

  /// Internal helper that actually performs the social sign-in call after
  /// role is confirmed. Returns true if sign-in succeeded, false if the
  /// user genuinely cancelled, and rethrows on any other error so the
  /// outer handler can show an appropriate message.
  Future<bool> _attemptSocialSignIn(String provider, UserRole? role) async {
    final service = ref.read(socialAuthServiceProvider);
    final result = provider == 'google'
        ? await service.signInWithGoogle()
        : await service.signInWithApple();

    await ref.read(authProvider.notifier).socialLogin(
          provider: result.provider,
          idToken: result.idToken,
          role: role == null ? null : (role == UserRole.photographer
              ? AppUserRole.photographer
              : AppUserRole.client),
          fullName: result.fullName,
        );
    return true;
  }

  Future<void> _handleSocialSignIn(String provider) async {
    if (_isLoading) return;
    if (!mounted) return;

    setState(() {
      _socialLoadingProvider = provider;
      _errorMessage = null;
    });



    // ── Mobile or Apple: use standard async flow ────────────────────────────
    try {
      await _attemptSocialSignIn(provider, widget.role);
    } on SocialAuthReauthNeeded catch (e) {
      // [16] Account reauth failed — the service already called disconnect()
      // to clear stale tokens. Retry once: Credential Manager will now show
      // a fresh consent/picker flow without the stale token blocking it.
      debugPrint(
          '[SocialAuth] SocialAuthReauthNeeded: ${e.message} — retrying with fresh session...');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        await _attemptSocialSignIn(provider, widget.role);
      } on SocialAuthReauthNeeded catch (e2) {
        if (!mounted) return;
        setState(() => _socialLoadingProvider = null);
        await AppPopup.show(
          context,
          title: 'Sign-in Failed',
          message:
              'Google account authentication failed. Please go to your phone\'s Google account settings and sign in again.\n\nDetail: ${e2.message}',
          isError: true,
        );
        return;
      } on SocialAuthCancelled {
        if (!mounted) return;
        setState(() {
          _socialLoadingProvider = null;
          _errorMessage = "Sign-in cancelled. Please try again.";
        });
        return;
      } on ApiException catch (apiErr) {
        if (!mounted) return;
        if (apiErr.statusCode == 400 && apiErr.message.toLowerCase().contains('create an account')) {
          // No account exists, and we didn't provide a role.
          // Prompt for role now, and retry using silent sign-in so we don't show the popup again!
          final selectedRole = await Navigator.of(context).push<UserRole>(
            MaterialPageRoute(
                builder: (_) => const RoleSelectionScreen(selectOnly: true)),
          );
          if (selectedRole == null) {
            setState(() => _socialLoadingProvider = null);
            return;
          }
          if (!mounted) return;
          try {
            await _attemptSocialSignIn(provider, selectedRole);
            final retryUser = ref.read(authProvider).valueOrNull;
            setState(() => _socialLoadingProvider = null);
            if (retryUser != null) _navigateAfterAuth(retryUser);
            return;
          } catch (e) {
            if (!mounted) return;
            setState(() => _socialLoadingProvider = null);
            await AppPopup.show(context,
                title: 'Sign-in Failed', message: e.toString(), isError: true);
            return;
          }
        }
        setState(() => _socialLoadingProvider = null);
        await AppPopup.show(context,
            title: 'Sign-in Failed', message: apiErr.message, isError: true);
        return;
      } catch (retryErr, retryStack) {
        debugPrint('[SocialAuth] Reauth retry error: $retryErr\n$retryStack');
        if (!mounted) return;
        setState(() => _socialLoadingProvider = null);
        await AppPopup.show(
          context,
          title: 'Sign-in Failed (Debug)',
          message: '[${retryErr.runtimeType}] $retryErr',
          isError: true,
        );
        return;
      }
    } on SocialAuthCancelled {
      // Android's Credential Manager fires a false "canceled" exception right
      // after the user picks an account (flutter/flutter#171761).
      // DO NOT call authenticate() again — that would show the picker a 2nd time.
      // Instead, try signInSilently() to retrieve the account the user already
      // selected, with zero UI.
      debugPrint(
          '[SocialAuth] SocialAuthCancelled — attempting silent recovery (no UI)...');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;

      try {
        final service = ref.read(socialAuthServiceProvider);

        // For Google: silently recover the already-picked account.
        // For Apple: no silent equivalent — treat as genuine cancel.
        if (provider == 'google') {
          final silentResult = await service.signInWithGoogleSilent();
          debugPrint(
              '[SocialAuth] Silent recovery result: ${silentResult == null ? "null (genuine cancel)" : "got token ✅"}');

          if (silentResult == null) {
            // Silent recovery returned null.
            //
            // On release builds (Play App Signing), the credential may not
            // have been cached before the false-cancel fired — especially on
            // first install. Retry authenticate() once more rather than
            // immediately showing an error.
            //
            // If the retry also fails we show the error; if it succeeds the
            // code below returns early after navigating.
            final debugDetail = service.lastSilentError;
            debugPrint(
                '[SocialAuth] silent=null (lastSilentError: $debugDetail) — retrying authenticate() once...');
            await Future<void>.delayed(const Duration(milliseconds: 300));
            if (!mounted) return;

            try {
              await _attemptSocialSignIn(provider, widget.role);
            } on SocialAuthCancelled {
              // Still cancelling after retry — genuine cancel.
              if (!mounted) return;
              setState(() {
                _socialLoadingProvider = null;
                _errorMessage = "Sign-in cancelled. Please try again.";
              });
              return;
            } on ApiException catch (retryApiErr) {
              if (!mounted) return;
              if (retryApiErr.statusCode == 400 && retryApiErr.message.toLowerCase().contains('create an account')) {
                 final selectedRole = await Navigator.of(context).push<UserRole>(
                    MaterialPageRoute(
                        builder: (_) => const RoleSelectionScreen(selectOnly: true)),
                  );
                  if (selectedRole == null) {
                    setState(() => _socialLoadingProvider = null);
                    return;
                  }
                  if (!mounted) return;
                  try {
                    await _attemptSocialSignIn(provider, selectedRole);
                    final retryUser = ref.read(authProvider).valueOrNull;
                    setState(() => _socialLoadingProvider = null);
                    if (retryUser != null) _navigateAfterAuth(retryUser);
                    return;
                  } catch (e) {
                    if (!mounted) return;
                    setState(() => _socialLoadingProvider = null);
                    await AppPopup.show(context,
                        title: 'Sign-in Failed', message: e.toString(), isError: true);
                    return;
                  }
              }
              setState(() => _socialLoadingProvider = null);
              await AppPopup.show(context,
                  title: 'Sign-in Failed',
                  message: retryApiErr.message,
                  isError: true);
              return;
            } catch (retryErr, retryStack) {
              debugPrint('[SocialAuth] Retry error: $retryErr\n$retryStack');
              if (!mounted) return;
              setState(() => _socialLoadingProvider = null);
              await AppPopup.show(
                context,
                title: 'Sign-in Failed (Debug)',
                message: '[${retryErr.runtimeType}] $retryErr',
                isError: true,
              );
              return;
            }

            // Retry succeeded — socialLogin() already called by _attemptSocialSignIn.
            if (!mounted) return;
            setState(() => _socialLoadingProvider = null);
            final retryUser = ref.read(authProvider).valueOrNull;
            if (retryUser != null) _navigateAfterAuth(retryUser);
            return;
          }

          // Silent sign-in succeeded — proceed with the recovered token.
          await ref.read(authProvider.notifier).socialLogin(
                provider: silentResult.provider,
                idToken: silentResult.idToken,
                role: widget.role == null ? null : (widget.role == UserRole.photographer
                    ? AppUserRole.photographer
                    : AppUserRole.client),
                fullName: silentResult.fullName,
              );
        } else {
          // Apple — no silent fallback, treat as genuine cancel.
          if (!mounted) return;
          setState(() {
            _socialLoadingProvider = null;
            _errorMessage = "Sign-in didn't go through — please try again.";
          });
          return;
        }
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() => _socialLoadingProvider = null);
        await AppPopup.show(context,
            title: 'Sign-in Failed', message: e.message, isError: true);
        return;
      } catch (e, stack) {
        debugPrint('[SocialAuth] Silent recovery error: $e\n$stack');
        if (!mounted) return;
        setState(() => _socialLoadingProvider = null);
        await AppPopup.show(
          context,
          title: 'Sign-in Failed (Debug)',
          // Show the REAL error so you can diagnose without USB:
          message: '[${e.runtimeType}] $e',
          isError: true,
        );
        return;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 400 && e.message.toLowerCase().contains('create an account')) {
        final selectedRole = await Navigator.of(context).push<UserRole>(
          MaterialPageRoute(
              builder: (_) => const RoleSelectionScreen(selectOnly: true)),
        );
        if (selectedRole == null) {
          setState(() => _socialLoadingProvider = null);
          return;
        }
        if (!mounted) return;
        try {
          await _attemptSocialSignIn(provider, selectedRole);
          final retryUser = ref.read(authProvider).valueOrNull;
          setState(() => _socialLoadingProvider = null);
          if (retryUser != null) _navigateAfterAuth(retryUser);
          return;
        } catch (e) {
          if (!mounted) return;
          setState(() => _socialLoadingProvider = null);
          await AppPopup.show(context,
              title: 'Sign-in Failed', message: e.toString(), isError: true);
          return;
        }
      }
      setState(() => _socialLoadingProvider = null);
      await AppPopup.show(context,
          title: 'Sign-in Failed', message: e.message, isError: true);
      return;
    } catch (e, stack) {
      debugPrint('Social Login Error: $e\n$stack');
      if (!mounted) return;
      setState(() => _socialLoadingProvider = null);
      await AppPopup.show(
        context,
        title: 'Sign-in Failed (Debug)',
        // Show the REAL error so you can diagnose without USB:
        message: '[${e.runtimeType}] $e',
        isError: true,
      );
      return;
    }

    if (!mounted) return;
    setState(() => _socialLoadingProvider = null);

    final user = ref.read(authProvider).valueOrNull;
    if (user == null) return;

    _navigateAfterAuth(user);
  }

  /// Sends the user to the right place after a successful login, in
  /// priority order: unverified email first, then an incomplete
  /// profile ([AppUser.hasCompletedProfile]), and only then role-based
  /// home. Each branch passes the argument shape that route actually
  /// expects per `app_routes.dart` (`verificationPending` wants a Map,
  /// `completeProfile` wants a raw `UserRole?`). `splash_screen.dart`
  /// (Task 10) reuses this same priority order and the same getter.
  ///
  /// The verification/profile branches use a plain `pushNamed` (not
  /// `pushNamedAndRemoveUntil`) so Login stays on the stack beneath the
  /// gate screen — otherwise the gate screen's back button has nothing
  /// to pop to and silently does nothing. Only the final, fully-set-up
  /// destination clears the whole stack, since you shouldn't be able to
  /// back out of Home into Login.
  void _navigateAfterAuth(AppUser user) {
    final legacyRole = user.role == AppUserRole.photographer
        ? UserRole.photographer
        : UserRole.client;
    final navigator = Navigator.of(context);

    if (!user.isEmailVerified) {
      navigator.pushNamed(
        AppRoutes.verificationPending,
        arguments: {'email': user.email, 'role': legacyRole},
      );
      return;
    }

    if (!user.hasCompletedProfile) {
      navigator.pushNamed(
        AppRoutes.completeProfile,
        arguments: legacyRole,
      );
      return;
    }

    final destination = legacyRole == UserRole.photographer
        ? AppRoutes.adminHome
        : AppRoutes.home;
    navigator.pushNamedAndRemoveUntil(destination, (route) => false);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void handleBack() {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed(AppRoutes.roleSelection);
      }
    }

    return PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.roleSelection);
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: CustomAppBar(onBack: handleBack),
        body: ScreenBackdrop(
          child: SafeArea(
            top: true,
            child: AuthContainer(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Center(child: LogoWidget(size: 56)),
                    const SizedBox(height: AppSpacing.lg),
                    Text('Welcome Back',
                        style: Theme.of(context).textTheme.headlineLarge),
                    const SizedBox(height: 6),
                    Text(
                      'Continue your creative journey.',
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
                    AnimatedBuilder(
                      animation: _shakeAnimation,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(_shakeAnimation.value, 0),
                        child: child,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CustomTextField(
                            label: 'Email',
                            icon: Icons.mail_outline_rounded,
                            keyboardType: TextInputType.emailAddress,
                            controller: _emailController,
                            validator: (v) => (v == null || !v.contains('@'))
                                ? 'Enter a valid email'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          CustomTextField(
                            label: 'Password',
                            icon: Icons.lock_outline_rounded,
                            obscureText: true,
                            controller: _passwordController,
                            validator: (v) => (v == null || v.length < 6)
                                ? 'Minimum 6 characters'
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              height: 22,
                              width: 22,
                              child: Checkbox(
                                value: _rememberMe,
                                activeColor: AppColors.primary,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6)),
                                onChanged: (v) =>
                                    setState(() => _rememberMe = v ?? false),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('Remember me',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: context.textMuted,
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context)
                              .pushNamed(AppRoutes.forgotPassword),
                          child: const Text('Forgot Password?',
                              style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    GradientButton(
                      label: 'Sign In',
                      isLoading: _isLoading,
                      onPressed:
                          _socialLoadingProvider != null ? null : _handleSignIn,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Row(
                      children: [
                        Expanded(child: Divider(color: context.borderColor)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or continue with',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                        Expanded(child: Divider(color: context.borderColor)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: SocialButton(
                            icon: Icons.g_mobiledata_rounded,
                            label: 'Google',
                            isLoading: _socialLoadingProvider == 'google',
                            onTap: () => _handleSocialSignIn('google'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: SocialButton(
                            icon: Icons.apple_rounded,
                            label: 'Apple',
                            isLoading: _socialLoadingProvider == 'apple',
                            onTap: () => _handleSocialSignIn('apple'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Center(
                      child: TextButton(
                        onPressed: () {
                          // TEMP DEBUG — remove once the client/studio
                          // role mismatch is confirmed fixed.
                          debugPrint(
                              '[ROLE_DEBUG] LoginScreen Create Account tapped, widget.role=${widget.role}');
                          Navigator.of(context).pushNamed(AppRoutes.register,
                              arguments: widget.role);
                        },
                        child: RichText(
                          text: TextSpan(
                            text: "Don't have an account? ",
                            style: TextStyle(
                                color: context.textMuted,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500),
                            children: [
                              TextSpan(
                                  text: 'Create Account',
                                  style: TextStyle(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
