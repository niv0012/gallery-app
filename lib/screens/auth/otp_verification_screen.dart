import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/inputs/otp_input_field.dart';
import '../../core/theme/theme_context.dart';

/// OTP Verification Screen — same glass/gradient auth language as
/// [EmailVerificationScreen], but for a numeric one-time code sent to
/// [contact] (an email address or phone number). Dummy navigation only:
/// entering a full-length code proceeds to Complete Profile, matching
/// the rest of the auth flow. Push with:
///
/// ```dart
/// Navigator.of(context).pushNamed(
///   AppRoutes.otpVerification,
///   arguments: emailOrPhone,
/// );
/// ```
class OtpVerificationScreen extends StatefulWidget {
  final String contact;
  final int otpLength;

  const OtpVerificationScreen({
    super.key,
    required this.contact,
    this.otpLength = 6,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  static const _resendSeconds = 30;

  String _code = '';
  String? _error;
  bool _verifying = false;
  bool _resending = false;
  int _secondsLeft = _resendSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _secondsLeft = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
        return;
      }
      setState(() => _secondsLeft--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0 || _resending) return;
    setState(() => _resending = true);
    await Future.delayed(
        const Duration(milliseconds: 900)); // dummy navigation only
    if (!mounted) return;
    setState(() {
      _resending = false;
      _error = null;
    });
    _startTimer();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('A new code has been sent.')),
    );
  }

  Future<void> _verify() async {
    if (_code.length != widget.otpLength) {
      setState(() => _error = 'Enter the full ${widget.otpLength}-digit code');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    await Future.delayed(
        const Duration(milliseconds: 900)); // dummy navigation only
    if (!mounted) return;
    setState(() => _verifying = false);
    Navigator.of(context).pushReplacementNamed(AppRoutes.completeProfile);
  }

  @override
  Widget build(BuildContext context) {
    final minutes = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsLeft % 60).toString().padLeft(2, '0');

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const CustomAppBar(title: 'Verify Code'),
      body: ScreenBackdrop(
        child: SafeArea(
          top: true,
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl, vertical: AppSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 92,
                          height: 92,
                          margin: const EdgeInsets.only(bottom: AppSpacing.xl),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: AppColors.heroGradient,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color:
                                    AppColors.primary.withValues(alpha: 0.32),
                                blurRadius: 32,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.sms_rounded,
                              color: Colors.white, size: 42),
                        ),
                      ),
                      Text(
                        'Enter Verification Code',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.contact.isEmpty
                            ? 'We\'ve sent a ${widget.otpLength}-digit code to your registered contact.'
                            : 'We\'ve sent a ${widget.otpLength}-digit code to\n${widget.contact}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: context.textMuted),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      OtpInputField(
                        length: widget.otpLength,
                        hasError: _error != null,
                        onChanged: (v) {
                          setState(() {
                            _code = v;
                            if (_error != null) _error = null;
                          });
                        },
                        onCompleted: (_) => _verify(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.error,
                              fontWeight: FontWeight.w600,
                              fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.xxl),
                      GradientButton(
                        label: 'Verify',
                        isLoading: _verifying,
                        onPressed: _verify,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Center(
                        child: _resending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.primary),
                              )
                            : TextButton(
                                onPressed: _secondsLeft == 0 ? _resend : null,
                                child: Text(
                                  _secondsLeft == 0
                                      ? 'Resend Code'
                                      : 'Resend code in $minutes:$seconds',
                                  style: TextStyle(
                                    color: _secondsLeft == 0
                                        ? AppColors.primary
                                        : context.textMuted,
                                    fontWeight: FontWeight.w700,
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
      ),
    );
  }
}
