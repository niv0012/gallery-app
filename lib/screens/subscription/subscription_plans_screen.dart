import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/subscription_plan_model.dart';
import '../../providers/auth_providers.dart';
import '../../providers/drawer_provider.dart';
import '../../widgets/cards/glass_card.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';

class SubscriptionPlansScreen extends ConsumerStatefulWidget {
  const SubscriptionPlansScreen({super.key});

  @override
  ConsumerState<SubscriptionPlansScreen> createState() =>
      _SubscriptionPlansScreenState();
}

class _SubscriptionPlansScreenState
    extends ConsumerState<SubscriptionPlansScreen> with WidgetsBindingObserver {
  late SubscriptionPlanModel _selectedPlan;
  final ScrollController _scrollController = ScrollController();

  // The external website where subscription purchases are completed.
  static const String _subscriptionWebsiteUrl =
      'https://picgallery.in/pricing.php';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize to Yearly plan as the default selected option
    _selectedPlan = SubscriptionPlanModel.forType(SubscriptionPlan.premium);

    // After build, set to user's current plan if possible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final currentPlanType = ref.read(subscriptionPlanProvider);
      final currentModel = SubscriptionPlanModel.forType(currentPlanType);
      setState(() {
        _selectedPlan = currentModel;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh user plan in case they just returned from the payment website
      ref.read(authProvider.notifier).refreshMe();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  void _showConfirmationSheet(SubscriptionPlanModel plan) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _ConfirmationBottomSheet(
        plan: plan,
        onConfirm: () async {
          Navigator.of(context).pop(); // close sheet

          if (plan.planType == SubscriptionPlan.trial) {
            try {
              // Show a loading indicator if needed, but the provider handles state
              await ref.read(authProvider.notifier).activatePlan('trial');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Free Trial Activated successfully!'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to activate trial: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          } else {
            await _redirectToSubscriptionWebsite();
          }
        },
      ),
    );
  }

  Future<void> _redirectToSubscriptionWebsite() async {
    final uri = Uri.parse(_subscriptionWebsiteUrl);
    final launched = await canLaunchUrl(uri) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open picgallery.in')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final subState = ref.watch(subscriptionStateProvider).valueOrNull;
    final currentPlanType = ref.watch(subscriptionPlanProvider);
    final currentModel = SubscriptionPlanModel.forType(currentPlanType);

    // trial_used comes directly from the backend via AppUser
    final user = ref.watch(authProvider).valueOrNull;
    final trialUsed = user?.trialUsed ?? false;
    final planActive = subState?.isActive ?? false;
    final daysRemaining = subState?.daysRemaining ?? -1;

    final isSelectedActive = _selectedPlan.planType == currentPlanType;
    // Lock trial button if already used and not currently on trial plan
    final isSelectedTrialLocked =
        _selectedPlan.planType == SubscriptionPlan.trial &&
            trialUsed &&
            currentPlanType != SubscriptionPlan.trial;

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Subscription Plans',
        showBack: true,
      ),
      body: Stack(
        children: [
          SafeArea(
            child: RefreshIndicator(
              onRefresh: () async {
                await ref.read(authProvider.notifier).refreshMe();
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Premium Hero Section Header
                  Center(
                    child: Column(
                      children: [
                        // Premium Visual Badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            gradient: AppColors.buttonGradient,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    AppColors.primary.withValues(alpha: 0.25),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star_rounded,
                                  color: Colors.white, size: 13),
                              SizedBox(width: 4),
                              Text(
                                'STUDIO ELITE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'Choose Your Plan',
                          style: Theme.of(context)
                              .textTheme
                              .headlineLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                                height: 1.15,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Unlock the full power of your studio',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                          textAlign: TextAlign.center,
                        ),
                        // Current Plan Indicator — only shown once the user
                        // actually has an active plan. `currentModel` used
                        // to silently fall back to the Trial plan for a
                        // brand-new/no-plan account (no `free` entry existed
                        // in SubscriptionPlanModel.plans), so this chip used
                        // to permanently read "Current Plan: 5-Day Free
                        // Trial" even when nothing was active. Fixed at the
                        // data level (plans now has a real `free` entry) AND
                        // gated here, so a no-plan user sees nothing at all,
                        // consistent with the Expiry/Active banners below.
                        if (planActive) ...[
                          const SizedBox(height: AppSpacing.md),
                          Builder(builder: (ctx) {
                            final isDark =
                                Theme.of(ctx).brightness == Brightness.dark;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: Theme.of(ctx).scaffoldBackgroundColor,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.md),
                                border: Border.all(
                                  color: isDark
                                      ? AppColors.darkBorder
                                      : AppColors.border,
                                ),
                                boxShadow: AppShadows.subtle,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: currentPlanType.color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Current Plan: ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppColors.subtitleOnDark
                                          : AppColors.subtitle,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    currentModel.name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppColors.textOnDark
                                          : AppColors.text,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  // ── Expiry Warning Banner (shown when ≤15 days remain) ─
                  if (planActive && daysRemaining >= 0 && daysRemaining <= 15)
                    Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.amber.shade800, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Your ${currentModel.name} expires in '
                              '$daysRemaining day${daysRemaining == 1 ? '' : 's'} — renew below to avoid interruption.',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.amber.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Active Plan Banner ─────────────────────────────────
                  if (planActive &&
                      !(daysRemaining >= 0 && daysRemaining <= 15))
                    Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_rounded,
                              color: AppColors.primary, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary),
                                children: [
                                  const TextSpan(text: "You're on the "),
                                  TextSpan(
                                    text: currentModel.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w900),
                                  ),
                                  if (subState?.expiresAt != null)
                                    TextSpan(
                                      text:
                                          // .toLocal() is required here: the backend stores/sends
                                          // expiry as UTC, and DateTime.parse keeps that UTC flag.
                                          // Formatting it directly (as before) displayed raw UTC
                                          // instead of the device's local time — 5:30 hours off
                                          // for an IST user.
                                          ' — active until ${DateFormat('dd MMM yyyy, hh:mm a').format(subState!.expiresAt!.toLocal())}',
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Plan Cards ─────────────────────────────────────────
                  // The 'free' entry in SubscriptionPlanModel.plans is a
                  // lookup-only placeholder (used by forType() so a no-plan
                  // user resolves correctly) — it must never be rendered as
                  // a purchasable/selectable card in this grid. Filtering it
                  // out here is what stops "No Active Plan — ACTIVE" from
                  // showing up above the real Trial/Pro/Premium cards.
                  ...SubscriptionPlanModel.plans
                      .where((plan) => plan.planType != SubscriptionPlan.free)
                      .map((plan) {
                    final isSelected = _selectedPlan.id == plan.id;
                    final isActive = currentPlanType == plan.planType;
                    final isPlanTrialLocked =
                        plan.planType == SubscriptionPlan.trial &&
                            trialUsed &&
                            !isActive;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: _PlanCard(
                        plan: plan,
                        isSelected: isSelected,
                        isActive: isActive,
                        isTrialLocked: isPlanTrialLocked,
                        onTap: () {
                          setState(() {
                            _selectedPlan = plan;
                          });
                        },
                      ),
                    );
                  }),

                  const SizedBox(height: AppSpacing.sm),
                  // CTA Button
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_selectedPlan.planType == SubscriptionPlan.premium)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Best value — save vs two 6-month cycles',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ElevatedButton(
                          onPressed: (isSelectedActive || isSelectedTrialLocked)
                              ? null
                              : () => _showConfirmationSheet(_selectedPlan),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                          ).copyWith(
                            backgroundColor:
                                WidgetStateProperty.resolveWith<Color?>(
                                    (states) {
                              if (states.contains(WidgetState.disabled)) {
                                return context.borderColor.withValues(alpha: 0.5);
                              }
                              return AppColors.primary;
                            }),
                          ),
                          child: Ink(
                            decoration:
                                (isSelectedActive || isSelectedTrialLocked)
                                    ? null
                                    : BoxDecoration(
                                        gradient: AppColors.buttonGradient,
                                        borderRadius:
                                            BorderRadius.circular(AppRadius.md),
                                      ),
                            child: Container(
                              alignment: Alignment.center,
                              child: Text(
                                isSelectedActive
                                    ? 'Current Plan'
                                    : isSelectedTrialLocked
                                        ? 'Trial Already Used'
                                        : _selectedPlan.planType ==
                                                SubscriptionPlan.trial
                                            ? 'Get Started Free'
                                            : currentPlanType ==
                                                    SubscriptionPlan.free
                                                ? 'Upgrade to ${_selectedPlan.name}'
                                                : 'Switch to ${_selectedPlan.name}',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: (isSelectedActive ||
                                          isSelectedTrialLocked)
                                      ? context.textMuted
                                      : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: AppSpacing.xl),

                  // Premium Benefits Section ("Everything your studio needs")
                  Text(
                    'Everything your studio needs',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildBenefitsGrid(),

                  const SizedBox(height: AppSpacing.xxl),

                  // Current Plan Status Details
                  _CurrentPlanStatusCard(
                    subState: subState,
                    currentPlan: currentModel,
                    trialUsed: trialUsed,
                    onExploreTap: () {
                      _scrollController.animateTo(
                        0,
                        duration: AppDurations.medium,
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                ],
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }

  Widget _buildBenefitsGrid() {
    final benefits = [
      (
        title: 'UNLIMITED GALLERIES',
        desc: 'Manage unlimited client galleries without restrictions.',
        icon: Icons.photo_album_rounded,
        color: AppColors.primary
      ),
      (
        title: 'UNLIMITED STORAGE',
        desc: 'Store and organize your studio media without plan limit.',
        icon: Icons.cloud_upload_rounded,
        color: AppColors.secondary
      ),
      (
        title: 'PRIORITY SUPPORT',
        desc: 'Get priority 24/7 client support assistance.',
        icon: Icons.support_agent_rounded,
        color: AppColors.accent
      ),
      (
        title: 'BACKUP PROTECTION',
        desc: 'Keep secure backup storage for your important studio media.',
        icon: Icons.security_rounded,
        color: AppColors.gold
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: benefits.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        mainAxisExtent: 136,
      ),
      itemBuilder: (context, i) {
        final b = benefits[i];
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return GlassCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          borderRadius: AppRadius.md,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: b.color.withValues(alpha: isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(b.icon, size: 18, color: b.color),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                b.title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppColors.textOnDark : AppColors.text,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              Expanded(
                child: Text(
                  b.desc,
                  style: TextStyle(
                    fontSize: 10,
                    color:
                        isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Custom Plan Card Widget ───────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final SubscriptionPlanModel plan;
  final bool isSelected;
  final bool isActive;
  final bool isTrialLocked;
  final VoidCallback onTap;

  const _PlanCard({
    required this.plan,
    required this.isSelected,
    required this.isActive,
    this.isTrialLocked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isYearly = plan.planType == SubscriptionPlan.premium;
    // Treat trial the same as free — no billing-period suffix, no paid styling.
    final isFree = plan.planType == SubscriptionPlan.free ||
        plan.planType == SubscriptionPlan.trial;

    // Premium Border & Shadow Styling
    Border? cardBorder;
    BoxShadow? cardShadow;
    Color? cardBackground;

    if (isSelected) {
      if (isYearly) {
        cardBorder = Border.all(color: AppColors.gold, width: 2.2);
        cardShadow = BoxShadow(
          color: AppColors.gold.withValues(alpha: 0.24),
          blurRadius: 20,
          offset: const Offset(0, 6),
        );
      } else if (!isFree) {
        cardBorder = Border.all(color: AppColors.primary, width: 2.2);
        cardShadow = BoxShadow(
          color: AppColors.primary.withValues(alpha: 0.18),
          blurRadius: 18,
          offset: const Offset(0, 6),
        );
      } else {
        cardBorder = Border.all(
            color: isDark ? AppColors.subtitleOnDark : AppColors.subtitle,
            width: 2.2);
      }
    } else {
      cardBorder = Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.border, width: 1);
    }

    if (isActive) {
      cardBackground = isFree
          ? (isDark ? Colors.grey.shade800 : Colors.grey.shade100)
          : (isDark
              ? AppColors.primary.withValues(alpha: 0.15)
              : const Color(0xFFF9F7FF));
    } else {
      cardBackground = isDark ? Colors.grey.shade900 : Colors.white;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        decoration: BoxDecoration(
          color: cardBackground,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: cardBorder,
          boxShadow: cardShadow != null ? [cardShadow] : AppShadows.subtle,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main Row: Name, Badge, Pricing
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              plan.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color: isDark
                                        ? AppColors.textOnDark
                                        : AppColors.text,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              plan.subtitle,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isDark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            textBaseline: TextBaseline.alphabetic,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            children: [
                              Text(
                                '${plan.currency}${plan.price.toStringAsFixed(0)}',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  color: isDark
                                      ? AppColors.textOnDark
                                      : AppColors.text,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              if (!isFree)
                                Text(
                                  ' / ${plan.billingPeriod}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              // Trial plan: show "Free / 5 Days" label
                              if (plan.planType == SubscriptionPlan.trial)
                                Text(
                                  ' / ${plan.duration}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ],
                          ),
                          if (isActive)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    plan.planType.color.withValues(alpha: 0.15),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Text(
                                'ACTIVE',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  color: plan.planType.color,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            )
                          else if (isTrialLocked)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey.withValues(alpha: 0.15),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Text(
                                'ALREADY USED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  color: context.textMuted,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: AppSpacing.md),
                  Divider(
                      height: 1,
                      color: isDark ? AppColors.darkBorder : AppColors.border),
                  const SizedBox(height: AppSpacing.md),

                  // Feature List
                  ...plan.features.map((feature) {
                    final isLimited = isFree &&
                        (feature.contains('Limited') ||
                            feature.contains('Standard'));
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(
                            isLimited
                                ? Icons.info_outline_rounded
                                : Icons.check_circle_rounded,
                            size: 15,
                            color: isLimited
                                ? Colors.amber.shade700
                                : (isFree
                                    ? (isDark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle)
                                    : AppColors.primary),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              feature,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: isLimited
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isLimited
                                    ? (isDark
                                        ? AppColors.textOnDark
                                        : AppColors.text)
                                    : (isDark
                                            ? AppColors.textOnDark
                                            : AppColors.text)
                                        .withValues(alpha: 0.8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),

                  // Show the backup chip for every paid and trial plan.
                  // (The free/unpaid tier has no backupDuration to display.)
                  if (plan.planType != SubscriptionPlan.free) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: (plan.planType == SubscriptionPlan.trial
                                ? context.textMuted
                                : isYearly
                                    ? AppColors.gold
                                    : AppColors.primary)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.cloud_done_rounded,
                            size: 14,
                            color: plan.planType == SubscriptionPlan.trial
                                ? context.textMuted
                                : isYearly
                                    ? AppColors.gold
                                    : AppColors.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            plan.backupDuration,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: plan.planType == SubscriptionPlan.trial
                                  ? context.textMuted
                                  : isYearly
                                      ? AppColors.gold
                                      : AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Top Ribbons / Badges
            if (isYearly)
              Positioned(
                top: -11,
                left: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.gold,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.gold.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.workspace_premium_rounded,
                          color: Colors.white, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'BEST VALUE • YEARLY SAVINGS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (plan.planType == SubscriptionPlan.pro)
              Positioned(
                top: -11,
                left: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Text(
                    '6 MONTHS RENEWAL',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Current Plan Status Details Widget ─────────────────────────────────

class _CurrentPlanStatusCard extends StatelessWidget {
  final SubscriptionPlanModel currentPlan;
  final SubscriptionState? subState;
  final bool trialUsed;
  final VoidCallback onExploreTap;

  const _CurrentPlanStatusCard({
    required this.currentPlan,
    this.subState,
    required this.trialUsed,
    required this.onExploreTap,
  });

  @override
  Widget build(BuildContext context) {
    final isFree = currentPlan.planType == SubscriptionPlan.free;
    final isTrial = subState?.isTrial == true;
    final isBasic = isFree && !isTrial;
    final hasExpiredTrial = isBasic && trialUsed;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isBasic ? Colors.grey.shade50 : AppColors.darkSurface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isBasic ? context.borderColor : AppColors.darkBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isBasic ? Icons.info_outline_rounded : Icons.verified_rounded,
                color: isBasic ? (hasExpiredTrial ? AppColors.error : context.textMuted) : AppColors.gold,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'Current Subscription Status',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: isBasic ? context.textPrimary : AppColors.textOnDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (isBasic) ...[
            Text(
              hasExpiredTrial ? "Your Trial has Expired" : "No Active Plan",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: hasExpiredTrial ? AppColors.error : context.textPrimary.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onExploreTap,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md)),
                  side: const BorderSide(color: AppColors.primary),
                  foregroundColor: AppColors.primary,
                ),
                child: const Text(
                  'Explore Premium Plans',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ] else ...[
            _buildStatusRow(context, 'Plan Type', currentPlan.name),
            _buildStatusRow(context, 'Status', 'Active', isValueGreen: true),
            _buildStatusRow(
                context,
                'Renewal Date',
                subState?.expiresAt != null
                    // .toLocal() — same fix as the banner above; expiresAt
                    // arrives from the backend as UTC.
                    ? DateFormat('dd MMM yyyy, hh:mm a')
                        .format(subState!.expiresAt!.toLocal())
                    : 'N/A'),
            if (subState != null && subState!.daysRemaining >= 0)
              _buildStatusRow(
                  context, 'Days Remaining', '${subState!.daysRemaining} days'),
            _buildStatusRow(context, 'Backup Type', currentPlan.backupDuration),
            const SizedBox(height: AppSpacing.md),
            const Divider(color: AppColors.darkBorder),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'Included Benefits:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppColors.subtitleOnDark,
              ),
            ),
            const SizedBox(height: 6),
            ...currentPlan.features.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.check_rounded,
                          color: AppColors.gold, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        f,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textOnDark,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusRow(BuildContext context, String label, String value,
      {bool isValueGreen = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.subtitleOnDark,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: isValueGreen ? AppColors.success : AppColors.textOnDark,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Confirmation Bottom Sheet Widget ───────────────────────────────────

class _ConfirmationBottomSheet extends StatelessWidget {
  final SubscriptionPlanModel plan;
  final VoidCallback onConfirm;

  const _ConfirmationBottomSheet({
    required this.plan,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xl),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle indicator
            Center(
              child: Container(
                width: 36,
                height: 4.5,
                decoration: BoxDecoration(
                  color: context.borderColor,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Crown or Star Header
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            Text(
              'Activate ${plan.name}?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              "You'll be redirected to picgallery.in to complete your subscription.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Cost summary box
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: context.bgColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Total Billing',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          plan.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${plan.currency}${plan.price.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Benefit points list
            Text(
              'Main Benefits Included:',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            ...plan.features.take(3).map((f) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: AppColors.primary, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        f,
                        style: TextStyle(
                            fontSize: 13,
                            color: context.textPrimary,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                )),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.cloud_done_rounded,
                      color: AppColors.primary, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    plan.backupDuration,
                    style: TextStyle(
                        fontSize: 13,
                        color: context.textPrimary,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Confirm & Cancel Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                      side:
                          BorderSide(color: context.borderColor, width: 1.5),
                      foregroundColor: context.textPrimary,
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onConfirm,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: const Text(
                      'Proceed to Payment',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
