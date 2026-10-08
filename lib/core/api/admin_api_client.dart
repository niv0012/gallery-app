import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Display helpers for the raw `subscription_status` string Supabase
/// returns (the `users.subscription_status` column) — unchanged from
/// the backend version.
extension SubscriptionStatusX on String {
  String get subscriptionLabel => switch (this) {
        'active' => 'Active',
        'trial' => 'Trial',
        'expired' => 'Expired',
        _ => 'No subscription',
      };

  Color get subscriptionColor => switch (this) {
        'active' => const Color(0xFF22C55E),
        'trial' => const Color(0xFFEFBF6B),
        'expired' => const Color(0xFFEF4444),
        _ => const Color(0xFF6B7280),
      };
}

/// Thrown for any failed admin action, carrying a message the UI can
/// show directly — mirrors the old backend's HTTPException `detail`,
/// now populated from Supabase Auth/Postgrest error messages instead.
class AdminApiException implements Exception {
  final int statusCode;
  final String message;
  AdminApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

class SuperAdmin {
  final String id;
  final String fullName;
  final String email;
  final bool isActive;

  SuperAdmin({
    required this.id,
    required this.fullName,
    required this.email,
    required this.isActive,
  });

  factory SuperAdmin.fromJson(Map<String, dynamic> json) => SuperAdmin(
        id: json['id'].toString(),
        fullName: (json['full_name'] as String?) ?? (json['email'] as String?) ?? 'Super Admin',
        email: (json['email'] as String?) ?? '',
        isActive: (json['is_active'] as bool?) ?? true,
      );
}

/// Fixed 24TB server capacity constant (24 * 1024^4 bytes).
const int platformCapacityBytes = 24 * 1024 * 1024 * 1024 * 1024;

/// Platform-wide storage usage data aggregated across all users.
class StorageSummary {
  final int totalUsedBytes;
  final int totalCapacityBytes;
  final Map<String, int> usedBytesByUserId;

  StorageSummary({
    required this.totalUsedBytes,
    required this.totalCapacityBytes,
    required this.usedBytesByUserId,
  });

  double get usedPercentage {
    if (totalCapacityBytes <= 0) return 0.0;
    final pct = (totalUsedBytes / totalCapacityBytes) * 100;
    return pct.clamp(0.0, 100.0);
  }

  factory StorageSummary.fromJson(Map<String, dynamic> json) {
    final totalUsed = (json['total_used_bytes'] as num?)?.toInt() ?? 0;
    final perUserList = json['per_user'] as List<dynamic>? ?? [];
    final map = <String, int>{};
    for (final item in perUserList) {
      if (item is Map<String, dynamic>) {
        final uid = item['user_id'] as String?;
        final bytes = (item['used_bytes'] as num?)?.toInt() ?? 0;
        if (uid != null) {
          map[uid] = bytes;
        }
      }
    }
    return StorageSummary(
      totalUsedBytes: totalUsed,
      totalCapacityBytes: platformCapacityBytes,
      usedBytesByUserId: map,
    );
  }
}

/// One row for either the Studio Users or Client Users list. Field
/// names match the `users` table's columns directly (Postgres/
/// Supabase returns snake_case), so this parses a raw Supabase row
/// exactly the way it used to parse the backend's JSON.
class PlatformUser {
  final String id;
  final String fullName;
  final String email;
  final String phone;
  final String type; // "studio" | "client"
  final DateTime joinedAt;
  final String? city;
  final String? studioName;
  final String subscriptionStatus; // "active" | "trial" | "expired" | "none"
  final String? currentPlan; // "trial" | "pro" | "premium" | null
  final DateTime? planStartedAt;
  final DateTime? planExpiry;
  final bool isActive; // false = suspended by a Super Admin
  final String? linkedAccountId;
  final int? usedBytes;

  PlatformUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.type,
    required this.joinedAt,
    this.city,
    this.studioName,
    this.subscriptionStatus = 'none',
    this.currentPlan,
    this.planStartedAt,
    this.planExpiry,
    this.isActive = true,
    this.linkedAccountId,
    this.usedBytes,
  });

  PlatformUser copyWith({
    String? id,
    String? fullName,
    String? email,
    String? phone,
    String? type,
    DateTime? joinedAt,
    String? city,
    String? studioName,
    String? subscriptionStatus,
    String? currentPlan,
    DateTime? planStartedAt,
    DateTime? planExpiry,
    bool? isActive,
    String? linkedAccountId,
    int? usedBytes,
  }) {
    return PlatformUser(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      type: type ?? this.type,
      joinedAt: joinedAt ?? this.joinedAt,
      city: city ?? this.city,
      studioName: studioName ?? this.studioName,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      currentPlan: currentPlan ?? this.currentPlan,
      planStartedAt: planStartedAt ?? this.planStartedAt,
      planExpiry: planExpiry ?? this.planExpiry,
      isActive: isActive ?? this.isActive,
      linkedAccountId: linkedAccountId ?? this.linkedAccountId,
      usedBytes: usedBytes ?? this.usedBytes,
    );
  }

  bool get isStudio =>
      type.toLowerCase() == 'studio' ||
      type.toLowerCase() == 'photographer' ||
      type.toLowerCase() == 'studio_owner';

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  factory PlatformUser.fromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] as String?) ?? (json['role'] as String?) ?? 'client';
    final joinedAtStr = (json['created_at'] as String?) ?? (json['joined_at'] as String?);
    final joinedAtDate = joinedAtStr != null
        ? (DateTime.tryParse(joinedAtStr) ?? DateTime.now())
        : DateTime.now();

    final planExpiryStr = json['plan_expiry'] as String?;
    final planExpiryDate = planExpiryStr != null ? DateTime.tryParse(planExpiryStr) : null;
    
    String subStatus = (json['subscription_status'] as String?) ?? (json['plan_status'] as String?) ?? 'none';
    
    if (subStatus == 'inactive') {
      subStatus = 'none';
    }
    
    if (planExpiryDate != null && DateTime.now().toUtc().isAfter(planExpiryDate)) {
      subStatus = 'expired';
    }

    if (subStatus == 'active' && json['current_plan'] == 'trial') {
      subStatus = 'trial';
    }

    return PlatformUser(
      id: json['id'].toString(),
      fullName: (json['full_name'] as String?) ?? (json['name'] as String?) ?? (json['email'] as String?) ?? 'User',
      email: (json['email'] as String?) ?? '',
      phone: (json['phone'] as String?) ?? '',
      type: rawType,
      joinedAt: joinedAtDate,
      city: json['city'] as String?,
      studioName: json['studio_name'] as String?,
      subscriptionStatus: subStatus,
      currentPlan: json['current_plan'] as String?,
      planStartedAt: json['plan_started_at'] != null
          ? DateTime.tryParse(json['plan_started_at'] as String)
          : null,
      planExpiry: planExpiryDate,
      isActive: (json['is_active'] as bool?) ?? true,
      linkedAccountId: json['linked_account_id'] as String?,
      usedBytes: (json['used_bytes'] as num?)?.toInt(),
    );
  }
}

/// Result of loading `users` — Studio Users and Client Users split
/// apart, matching the old `PlatformUsersRead` shape.
class PlatformUsers {
  final List<PlatformUser> studios;
  final List<PlatformUser> clients;

  PlatformUsers({required this.studios, required this.clients});
}

/// Talks to Supabase directly (Auth + Postgrest) instead of a FastAPI
/// backend. All access control that used to live in backend route
/// handlers now lives in Postgres Row Level Security policies — see
/// `supabase/migration.sql`. This class keeps the exact same public
/// method names/shapes as the old backend-backed version so none of
/// the screens that call it needed to change, with one exception:
/// [resetPassword] now also takes `email`, since Supabase's OTP verify
/// needs it (see that method's doc comment).
class AdminApiClient {
  AdminApiClient._();
  static final AdminApiClient instance = AdminApiClient._();

  SupabaseClient get _client => Supabase.instance.client;

  Future<bool> get isLoggedIn async => _client.auth.currentSession != null;

  /// Signs out of Supabase Auth. Named `clearToken` to match the old
  /// method name the screens already call.
  Future<void> clearToken() async {
    await _client.auth.signOut();
  }

  /// Signs in with Supabase Auth, then confirms the account is listed
  /// in `super_admins` (and still active). Signing in alone only
  /// proves *some* Supabase account exists with this email/password —
  /// it does NOT prove it's a Super Admin, since regular studio/client
  /// accounts use the same `auth.users` table. This second check is
  /// what the old backend's separate `admin:` JWT subject prefix used
  /// to guarantee.
  Future<SuperAdmin> login({required String email, required String password}) async {
    final AuthResponse authResponse;
    try {
      authResponse = await _client.auth
          .signInWithPassword(email: email, password: password)
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (e) {
      throw AdminApiException(401, e.message);
    }

    final authUser = authResponse.user;
    if (authUser == null) {
      throw AdminApiException(401, 'Login failed');
    }

    final Map<String, dynamic>? adminRow;
    try {
      final userEmail = authUser.email ?? email;
      adminRow = await _client
          .from('super_admins')
          .select()
          .eq('email', userEmail)
          .maybeSingle();
    } on PostgrestException catch (e) {
      await _client.auth.signOut();
      throw AdminApiException(500, e.message);
    }

    if (adminRow == null) {
      await _client.auth.signOut();
      throw AdminApiException(403, 'This account is not a Super Admin.');
    }
    if (adminRow['is_active'] == false) {
      await _client.auth.signOut();
      throw AdminApiException(403, 'This Super Admin account has been deactivated.');
    }

    return SuperAdmin.fromJson(adminRow);
  }

  /// Requests a password-reset code by email. Like the old backend,
  /// always resolves without throwing — Supabase's
  /// `resetPasswordForEmail` doesn't reveal whether the address has an
  /// account either, so this still can't be used to enumerate admins.
  ///
  /// SETUP NOTE: by default Supabase's reset email only contains a
  /// magic link, not a typeable 6-digit code. To keep this screen's
  /// "enter the code" UX, open Supabase Dashboard → Authentication →
  /// Email Templates → "Reset Password" and make sure `{{ .Token }}`
  /// is included in the template (it's the 6-digit OTP, separate from
  /// `{{ .ConfirmationURL }}`).
  Future<String> forgotPassword({
    required String email,
    String redirectTo = 'http://localhost:3000',
  }) async {
    try {
      await _client.auth
          .resetPasswordForEmail(email, redirectTo: redirectTo)
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (e) {
      debugPrint('[Supabase AuthException] code: ${e.code}, statusCode: ${e.statusCode}, message: ${e.message}');
      if (e.statusCode == '500' || e.code == 'unexpected_failure') {
        throw AdminApiException(
          500,
          'Unable to send reset code. Please try again or check Supabase SMTP configuration.',
        );
      }
      throw AdminApiException(int.tryParse(e.statusCode ?? '400') ?? 400, e.message);
    } catch (e, stack) {
      debugPrint('[Supabase Unknown Exception] $e\n$stack');
      throw AdminApiException(500, 'Unable to send reset code. Please try again.');
    }
    return 'If that email has a Super Admin account, a reset code is on its way.';
  }

  /// Exchanges a PKCE authorization code received via email link
  /// redirect for an authenticated session.
  Future<AuthSessionUrlResponse> exchangeCodeForSession(String code) async {
    try {
      return await _client.auth
          .exchangeCodeForSession(code)
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (e) {
      debugPrint('[Supabase AuthException exchangeCodeForSession] code: ${e.code}, statusCode: ${e.statusCode}, message: ${e.message}');
      final msg = e.message.toLowerCase();
      if (msg.contains('code verifier') || msg.contains('code_verifier')) {
        throw AdminApiException(
          400,
          'This reset link must be opened in the same browser window and profile you requested it from. Please request a new link.',
        );
      }
      throw AdminApiException(
        int.tryParse(e.statusCode ?? '400') ?? 400,
        e.message.isNotEmpty
            ? e.message
            : 'Password reset link is invalid or has expired.',
      );
    } catch (e, stack) {
      debugPrint('[Supabase exchangeCodeForSession Exception] $e\n$stack');
      throw AdminApiException(
        400,
        'Password reset link is invalid or has expired. Please request a new one.',
      );
    }
  }

  /// Updates the authenticated admin's password after establishing a
  /// session via PKCE code exchange, then signs out.
  Future<String> updatePasswordSession({required String newPassword}) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: newPassword));
    } on AuthException catch (e) {
      debugPrint('[Supabase AuthException updateUser] code: ${e.code}, statusCode: ${e.statusCode}, message: ${e.message}');
      throw AdminApiException(int.tryParse(e.statusCode ?? '400') ?? 400, e.message);
    } catch (e, stack) {
      debugPrint('[Supabase updateUser Exception] $e\n$stack');
      throw AdminApiException(400, 'Failed to update password. Please try again.');
    }

    await _client.auth.signOut();
    return 'Password reset. Please sign in again.';
  }

  /// Verifies the emailed code and sets the new password.
  ///
  /// Takes `email` in addition to the old `token`/`newPassword` params
  /// — Supabase's OTP verification needs the email the code was sent
  /// to, whereas the old backend endpoint could look that up from the
  /// token alone. `super_admin_reset_password_screen.dart` already has
  /// the email (it's passed in from the forgot-password screen), so
  /// this only needs a one-line change at its call site.
  Future<String> resetPassword({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanToken = token.trim();

    try {
      await _client.auth
          .verifyOTP(
            email: cleanEmail,
            token: cleanToken,
            type: OtpType.recovery,
          )
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (e) {
      debugPrint('[Supabase AuthException verifyOTP] code: ${e.code}, statusCode: ${e.statusCode}, message: ${e.message}');
      throw AdminApiException(int.tryParse(e.statusCode ?? '400') ?? 400, e.message);
    } catch (e, stack) {
      debugPrint('[Supabase verifyOTP Exception] $e\n$stack');
      throw AdminApiException(400, 'Invalid or expired reset code.');
    }

    try {
      await _client.auth.updateUser(UserAttributes(password: newPassword));
    } on AuthException catch (e) {
      debugPrint('[Supabase AuthException updateUser] code: ${e.code}, statusCode: ${e.statusCode}, message: ${e.message}');
      throw AdminApiException(int.tryParse(e.statusCode ?? '400') ?? 400, e.message);
    } catch (e, stack) {
      debugPrint('[Supabase updateUser Exception] $e\n$stack');
      throw AdminApiException(400, 'Failed to update password. Please try again.');
    }

    // Match the old behaviour: this endpoint doesn't leave the admin
    // signed in, it sends them back to log in fresh.
    await _client.auth.signOut();
    return 'Password reset. Please sign in again.';
  }

  /// Loads every row from `users`, split into Studio Users and Client
  /// Users. Relies on an RLS policy that only lets a signed-in
  /// `super_admins` row read every user (a regular user can only see
  /// their own row) — see `migration.sql`.
  Future<PlatformUsers> fetchUsers() async {
    if (!await isLoggedIn) {
      throw AdminApiException(401, 'Not signed in.');
    }

    final List<dynamic> rows;
    try {
      rows = await _client.from('users').select().order('created_at', ascending: false);
    } on PostgrestException catch (e) {
      debugPrint('[Supabase PostgrestException fetchUsers] ${e.message}');
      throw AdminApiException(500, e.message.isNotEmpty ? e.message : 'Could not load users.');
    } catch (e, stack) {
      debugPrint('[Supabase Exception fetchUsers] $e\n$stack');
      throw AdminApiException(500, 'Could not load users.');
    }

    final studios = <PlatformUser>[];
    final clients = <PlatformUser>[];
    for (final row in rows) {
      final user = PlatformUser.fromJson(row as Map<String, dynamic>);
      (user.isStudio ? studios : clients).add(user);
    }
    return PlatformUsers(studios: studios, clients: clients);
  }

  /// Calls the `get_platform_storage_summary` RPC function to retrieve
  /// platform-wide used storage bytes and per-user storage breakdowns.
  Future<StorageSummary> fetchStorageSummary() async {
    if (!await isLoggedIn) {
      throw AdminApiException(401, 'Not signed in.');
    }

    try {
      final res = await _client.rpc('get_platform_storage_summary');
      final Map<String, dynamic> data;
      if (res is String) {
        data = jsonDecode(res) as Map<String, dynamic>;
      } else if (res is Map) {
        data = Map<String, dynamic>.from(res);
      } else {
        data = <String, dynamic>{};
      }
      return StorageSummary.fromJson(data);
    } on PostgrestException catch (e) {
      debugPrint('[Supabase PostgrestException fetchStorageSummary] ${e.message}');
      // Safe fallback if SQL function has not been created yet in Supabase Dashboard
      return StorageSummary(
        totalUsedBytes: 0,
        totalCapacityBytes: platformCapacityBytes,
        usedBytesByUserId: {},
      );
    } catch (e, stack) {
      debugPrint('[Supabase Exception fetchStorageSummary] $e\n$stack');
      return StorageSummary(
        totalUsedBytes: 0,
        totalCapacityBytes: platformCapacityBytes,
        usedBytesByUserId: {},
      );
    }
  }

  /// Shared by suspendUser/unsuspendUser — flips `is_active` on a
  /// `users` row. The RLS policy for `UPDATE` on `users` only allows
  /// this when the caller is an active `super_admins` row, so a
  /// regular user's own client can't call this on themselves or
  /// anyone else even though the anon key is public.
  Future<PlatformUser> _setUserActive({
    required String userId,
    required bool active,
  }) async {
    if (!await isLoggedIn) {
      throw AdminApiException(401, 'Not signed in.');
    }

    try {
      final row = await _client
          .from('users')
          .update({'is_active': active})
          .eq('id', userId)
          .select()
          .single();
      return PlatformUser.fromJson(row);
    } on PostgrestException catch (e) {
      throw AdminApiException(
        403,
        e.message.isNotEmpty
            ? e.message
            : 'Could not ${active ? 'reactivate' : 'suspend'} this account.',
      );
    }
  }

  Future<PlatformUser> suspendUser(String userId) =>
      _setUserActive(userId: userId, active: false);

  Future<PlatformUser> unsuspendUser(String userId) =>
      _setUserActive(userId: userId, active: true);

  /// Checks the stored Supabase session is still valid and still
  /// belongs to an active Super Admin (covers: token expired, or this
  /// admin's access was revoked by someone else since they last opened
  /// the app).
  Future<SuperAdmin?> fetchCurrentAdmin() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final Map<String, dynamic>? adminRow;
    try {
      final userEmail = authUser.email ?? '';
      adminRow = await _client
          .from('super_admins')
          .select()
          .eq('email', userEmail)
          .maybeSingle();
    } on PostgrestException {
      await clearToken();
      return null;
    }

    if (adminRow == null || adminRow['is_active'] == false) {
      await clearToken();
      return null;
    }
    return SuperAdmin.fromJson(adminRow);
  }
}
