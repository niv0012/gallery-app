import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/legal_provider.dart';
import '../../../widgets/common/custom_app_bar.dart';
import '../../../widgets/common/inline_error_banner.dart';
import '../../../widgets/common/loading_widget.dart';
import '../common/expandable_faq_section.dart';
import 'help_support_content.dart';
import '../../../core/theme/theme_context.dart';

/// Unwraps [ApiException] to its `message` (already the FastAPI `detail`
/// string), falling back to a generic message for anything else (timeout,
/// no network, unexpected parse failure).
String _friendlyError(Object error) {
  return error is ApiException
      ? error.message
      : 'Something went wrong. Please try again.';
}

class HelpSupportScreen extends ConsumerWidget {
  const HelpSupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contentAsync = ref.watch(helpSupportProvider);

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Help & Support',
      ),
      body: SafeArea(
        child: contentAsync.when(
          data: (content) => SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IntroBlock(lastUpdated: content.lastUpdated),
                const SizedBox(height: AppSpacing.lg),
                for (final section in content.faqSections) ...[
                  ExpandableFaqSection(section: section),
                  const SizedBox(height: AppSpacing.md),
                ],
                const SizedBox(height: AppSpacing.xl),
                _ContactBlock(contact: content.contact),
              ],
            ),
          ),
          loading: () => const Center(
            child: LoadingWidget(message: 'Loading help & support...'),
          ),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: InlineErrorBanner(
                message:
                    'Couldn\'t load help & support. ${_friendlyError(error)}',
                action: TextButton(
                  onPressed: () => ref.invalidate(helpSupportProvider),
                  child: const Text('Retry'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroBlock extends StatelessWidget {
  final String lastUpdated;

  const _IntroBlock({required this.lastUpdated});

  @override
  Widget build(BuildContext context) {
    return GlassInfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Frequently Asked Questions',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Browse common topics. If you still need help, reach out to support using the contact options below.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'Last updated: $lastUpdated',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: context.textMuted,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _ContactBlock extends StatelessWidget {
  final SupportContact contact;

  const _ContactBlock({required this.contact});

  /// Actually performs a [SupportAction] instead of just acknowledging it
  /// with a toast: `email` opens the mail app pre-addressed to the
  /// payload, `phone` opens the dialer with the payload number, and
  /// `copy` puts the payload on the clipboard. Falls back to a toast only
  /// if the platform can't launch the mail/phone intent (e.g. no mail
  /// app configured on the device).
  Future<void> _runAction(BuildContext context, SupportAction action) async {
    switch (action.type) {
      case SupportActionType.email:
        final uri = Uri(scheme: 'mailto', path: action.payload);
        bool launched = false;
        try {
          launched = await launchUrl(uri);
        } catch (_) {}

        if (!launched && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No email app is available on this device.')),
          );
        }
        break;
      case SupportActionType.phone:
        final uri = Uri(scheme: 'tel', path: action.payload);
        bool launched = false;
        try {
          launched = await launchUrl(uri);
        } catch (_) {}

        if (!launched && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No phone app is available on this device.')),
          );
        }
        break;
      case SupportActionType.copy:
        await Clipboard.setData(ClipboardData(text: action.payload));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${action.payload} copied to clipboard')),
          );
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassInfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            contact.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Email: ${contact.email}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Phone: ${contact.phone}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final action in contact.actions)
                FilledButton.tonal(
                  onPressed: () => _runAction(context, action),
                  child: Text(action.label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class GlassInfoCard extends StatelessWidget {
  final Widget child;

  const GlassInfoCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.darkSurface
            : Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark
              ? AppColors.darkBorder
              : AppColors.border.withValues(alpha: 0.9),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}
