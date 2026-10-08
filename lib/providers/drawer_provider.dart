import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_providers.dart';

// ─── Subscription plan enum ───────────────────────────────────────────────────

/// Studio subscription tiers.
enum SubscriptionPlan {
  free('UPGRADE', Color(0xFF9CA3AF)),
  trial('TRIAL', Color(0xFF10B981)),
  pro('PRO', AppDrawerPlanColors.pro),
  premium('PREMIUM', AppDrawerPlanColors.premium);

  final String label;
  final Color color;
  const SubscriptionPlan(this.label, this.color);

  String get name {
    switch (this) {
      case SubscriptionPlan.free:
        return 'No Plan';
      case SubscriptionPlan.trial:
        return 'Trial';
      case SubscriptionPlan.pro:
        return 'Pro';
      case SubscriptionPlan.premium:
        return 'Premium';
    }
  }
}

/// Brand colors for plan badges — kept separate to avoid import cycles.
class AppDrawerPlanColors {
  AppDrawerPlanColors._();
  static const Color pro = Color(0xFF7C5CFF);
  static const Color premium = Color(0xFFEFBF6B);
}

// ─── Subscription state ───────────────────────────────────────────────────────

/// Full subscription lifecycle state persisted across app restarts.
class SubscriptionState {
  final SubscriptionPlan plan;

  /// When the current plan was activated (exact DateTime, including time-of-day).
  final DateTime? activatedAt;

  /// When the current plan expires (same time-of-day as [activatedAt]).
  final DateTime? expiresAt;

  /// Whether this activation was a free trial.
  final bool isTrial;

  const SubscriptionState({
    required this.plan,
    this.activatedAt,
    this.expiresAt,
    this.isTrial = false,
  });

  SubscriptionState copyWith({
    SubscriptionPlan? plan,
    DateTime? activatedAt,
    DateTime? expiresAt,
    bool? isTrial,
  }) =>
      SubscriptionState(
        plan: plan ?? this.plan,
        activatedAt: activatedAt ?? this.activatedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        isTrial: isTrial ?? this.isTrial,
      );

  // ── Computed helpers ──────────────────────────────────────────────────────

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  int get daysRemaining {
    if (expiresAt == null) return -1;
    final diff = expiresAt!.difference(DateTime.now());
    return diff.inDays.clamp(0, 99999);
  }

  bool get isActive => !isExpired && plan != SubscriptionPlan.free;

  // ── SharedPreferences keys ────────────────────────────────────────────────
  static const _kPlan = 'sub_plan';
  static const _kActivatedAt = 'sub_activated_at';
  static const _kExpiresAt = 'sub_expires_at';
  static const _kIsTrial = 'sub_is_trial';

  /// Persist this state to SharedPreferences.
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPlan, plan.name);
    if (activatedAt != null) {
      await prefs.setString(_kActivatedAt, activatedAt!.toIso8601String());
    }
    if (expiresAt != null) {
      await prefs.setString(_kExpiresAt, expiresAt!.toIso8601String());
    }
    await prefs.setBool(_kIsTrial, isTrial);
  }

  /// Load persisted state, or return null if nothing is stored.
  static Future<SubscriptionState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final planName = prefs.getString(_kPlan);
    if (planName == null) return null;

    final plan = SubscriptionPlan.values.firstWhere(
      (p) => p.name == planName,
      orElse: () => SubscriptionPlan.free,
    );
    final activatedRaw = prefs.getString(_kActivatedAt);
    final expiresRaw = prefs.getString(_kExpiresAt);
    final isTrial = prefs.getBool(_kIsTrial) ?? false;

    return SubscriptionState(
      plan: plan,
      activatedAt:
          activatedRaw != null ? DateTime.tryParse(activatedRaw) : null,
      expiresAt: expiresRaw != null ? DateTime.tryParse(expiresRaw) : null,
      isTrial: isTrial,
    );
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────

/// The single source of truth for the studio's subscription status.
///
/// On first launch with no stored data the 5-day free trial is automatically
/// activated (starting from [DateTime.now()]).
///
/// Widgets that previously watched `subscriptionPlanProvider` (which exposed a
/// plain [SubscriptionPlan]) now watch `subscriptionStateProvider` and read
/// `.plan` from it. A thin compatibility shim `subscriptionPlanProvider`
/// delegates to it so existing code doesn't need to change.
final subscriptionStateProvider =
    AsyncNotifierProvider<SubscriptionStateNotifier, SubscriptionState>(
        SubscriptionStateNotifier.new);

class SubscriptionStateNotifier extends AsyncNotifier<SubscriptionState> {
  @override
  Future<SubscriptionState> build() async {
    final authState = ref.watch(authProvider);
    final user = authState.valueOrNull;

    if (user == null) {
      return const SubscriptionState(plan: SubscriptionPlan.free);
    }

    // Determine plan from backend's currentPlan field
    SubscriptionPlan plan = SubscriptionPlan.free;
    if (user.currentPlan == 'premium') {
      plan = SubscriptionPlan.premium;
    } else if (user.currentPlan == 'pro') {
      plan = SubscriptionPlan.pro;
    } else if (user.currentPlan == 'trial' ||
        user.subscriptionStatus == 'trial') {
      plan = SubscriptionPlan.trial;
    }

    // Determine if it's expired based on backend's subscriptionStatus or planExpiry
    bool isExpired = false;
    if (user.subscriptionStatus == 'expired') {
      isExpired = true;
    } else if (user.planExpiry != null &&
        DateTime.now().isAfter(user.planExpiry!)) {
      isExpired = true;
    }

    if (isExpired) {
      plan = SubscriptionPlan.free;
    }

    return SubscriptionState(
      plan: plan,
      activatedAt: user.planStartedAt,
      expiresAt: user.planExpiry,
      isTrial: user.subscriptionStatus == 'trial' && !isExpired,
    );
  }

  /// Refreshes the subscription state by refreshing the auth provider,
  /// causing the backend to be re-polled for the latest user info.
  Future<void> refreshFromBackend() async {
    await ref.read(authProvider.notifier).refreshMe();
  }

  /// These methods are kept for API compatibility with older widgets,
  /// but they now just immediately refresh from the backend since the
  /// backend is the source of truth.
  Future<void> setPlan(
    SubscriptionPlan plan, {
    DateTime? activatedAt,
    DateTime? expiresAt,
  }) async {
    await refreshFromBackend();
  }

  Future<void> startTrial() async {
    await refreshFromBackend();
  }

  Future<void> expire() async {
    await refreshFromBackend();
  }
}

/// Thin shim so all existing widgets that watch [subscriptionPlanProvider]
/// keep working without modification.
final subscriptionPlanProvider = Provider<SubscriptionPlan>((ref) {
  final subState = ref.watch(subscriptionStateProvider);
  return subState.valueOrNull?.plan ?? SubscriptionPlan.free;
});

// ─── Drawer navigation state (unchanged) ─────────────────────────────────────

/// Identifies which [StudioDrawer] menu row is currently highlighted.
final selectedDrawerItemProvider =
    NotifierProvider<SelectedDrawerItemNotifier, String>(
        SelectedDrawerItemNotifier.new);

class SelectedDrawerItemNotifier extends Notifier<String> {
  @override
  String build() => 'dashboard';

  void select(String id) => state = id;
}
