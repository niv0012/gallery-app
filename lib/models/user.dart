/// Mirrors the backend's `UserRole` enum (`app/models/user.py`). Named
/// `AppUserRole` (rather than `UserRole`) to avoid clashing with the
/// dummy-navigation `UserRole` enum already declared in
/// `core/routes/app_routes.dart` â€” files that need both can import each
/// without a name collision.
enum AppUserRole {
  photographer,
  client;

  static AppUserRole fromJson(String value) {
    return AppUserRole.values.firstWhere(
      (r) => r.name == value,
      orElse: () => throw ArgumentError('Unknown role: $value'),
    );
  }

  String toJson() => name;
}

/// Parses a subscription-timestamp string (`plan_started_at` / `plan_expiry`)
/// from the backend, always treating it as UTC.
///
/// The backend is supposed to send these with an explicit UTC offset, but
/// `plan_expiry`'s underlying DB column is `timestamp` (no timezone) rather
/// than `timestamptz` â€” see the comment above `plan_expiry` in
/// `app/models/user.py`. Postgres silently drops the offset on write, so the
/// value can come back as a bare string like "2026-08-24T10:13:00" with no
/// "Z"/offset suffix. `DateTime.parse` treats a string like that as *local*
/// device time, not UTC, which made the Renewal Date / subscription banner
/// show a time up to several hours off (5:30 for IST users) once `.toLocal()`
/// was applied downstream.
///
/// This mirrors the same defensive fix already used server-side in
/// `app/api/deps.py` (re-tagging a naive datetime as UTC before comparing)
/// so the app is correct regardless of whether that DB column ever gets
/// migrated to `timestamptz`.
DateTime? _parseUtcTimestamp(String? raw) {
  if (raw == null) return null;
  final parsed = DateTime.parse(raw);
  if (parsed.isUtc) return parsed;
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

/// Plain Dart mirror of the backend's `UserRead` schema
/// (`app/schemas/user.py`). Field names are camelCase on the Dart side;
/// [fromJson]/[toJson] translate to/from the backend's snake_case keys.
class AppUser {
  final String id;
  final String fullName;
  final String email;
  final String authProvider;

  final AppUserRole role;
  final String? studioName;
  final String? studioAddress;
  final String? businessType;
  final String? avatarUrl;
  final String? coverImageUrl;
  final String? country;
  final String? state;
  final String? city;
  final String? address;
  final String? bio;
  final List<String>? specializations;
  final bool isEmailVerified;
  final bool cameraPermissionGranted;
  final bool photoLibraryPermissionGranted;
  final bool pushNotificationsEnabled;
  final bool emailNotificationsEnabled;

  /// Privacy & Security screen â€” "Download Permissions" toggle. Whether
  /// this user allows their galleries/media to be downloaded.
  final bool allowDownloads;

  /// Privacy & Security screen â€” "Account Privacy" toggle. Controls
  /// profile visibility for both studios and clients (`private_profile`
  /// on the backend).
  final bool privateProfile;

  /// App Settings screen â€” "App Language" picker (e.g. "English",
  /// "Hindi", "Spanish"). Shared by both roles.
  final String appLanguage;
  final DateTime createdAt;

  // Studio profile fields (Task 3 backend / Task 8-9 Flutter) â€” populated
  // only for photographer ("Studio") accounts, always null for clients.
  final int? yearEstablished;
  final int? teamSize;
  final List<String>? serviceAreas;
  final String? studioType;
  final int? experienceYears;
  final List<String>? languages;
  final String? equipmentHighlights;
  final double? pricingMin;
  final double? pricingMax;
  final String? packageDetails;
  final List<String>? availabilityDays;
  final String? instagramUrl;
  final String? facebookUrl;
  final String? youtubeUrl;
  final String? pinterestUrl;
  final String? website;

  // Client optional profile fields (Task 4 backend / Task 8 Flutter) â€”
  // populated only for client accounts, always null for photographers.
  // Gender, Date of Birth, Preferred City, and Budget Min/Max were
  // dropped from the app (edit screen no longer collects them; they
  // were never surfaced anywhere else) â€” only Preferred Photo Types
  // remains, since studios see it via `ClientSummary` on Connections.
  final String? profilePhotoUrl;
  final List<String>? preferredPhotoTypes;

  // Subscription backend fields (mirrors PlatformUserRead)
  final String subscriptionStatus; // "active" | "trial" | "expired" | "none"
  final String? currentPlan; // "trial" | "pro" | "premium"
  final DateTime? planStartedAt;
  final DateTime? planExpiry;

  /// Whether the user has ever activated the free trial (set to true by the
  /// backend the moment the trial is granted â€” stays true even after it
  /// expires so the user cannot re-claim it).
  final bool trialUsed;

  /// Whether [CompleteProfileScreen] has actually been filled in â€” used
  /// by `login_screen.dart` and `splash_screen.dart` to decide whether
  /// to route there before Home/Admin Home. Every role must have set a
  /// bio; photographers must additionally have set a studio name, since
  /// those are the fields that screen actually collects.
  bool get hasCompletedProfile {
    if (role == AppUserRole.photographer &&
        (studioName == null || studioName!.trim().isEmpty)) {
      return false;
    }
    return bio != null && bio!.trim().isNotEmpty;
  }

  const AppUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.authProvider,
    required this.role,
    this.studioName,
    this.studioAddress,
    this.businessType,
    this.avatarUrl,
    this.coverImageUrl,
    this.country,
    this.state,
    this.city,
    this.address,
    this.bio,
    this.specializations,
    required this.isEmailVerified,
    required this.cameraPermissionGranted,
    required this.photoLibraryPermissionGranted,
    required this.pushNotificationsEnabled,
    this.emailNotificationsEnabled = true,
    required this.allowDownloads,
    this.privateProfile = false,
    this.appLanguage = 'English',
    required this.createdAt,
    this.yearEstablished,
    this.teamSize,
    this.serviceAreas,
    this.studioType,
    this.experienceYears,
    this.languages,
    this.equipmentHighlights,
    this.pricingMin,
    this.pricingMax,
    this.packageDetails,
    this.availabilityDays,
    this.instagramUrl,
    this.facebookUrl,
    this.youtubeUrl,
    this.pinterestUrl,
    this.website,
    this.profilePhotoUrl,
    this.preferredPhotoTypes,
    this.subscriptionStatus = 'none',
    this.currentPlan,
    this.planStartedAt,
    this.planExpiry,
    this.trialUsed = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      email: json['email'] as String,
      authProvider: json['auth_provider'] as String? ?? 'local',
      role: AppUserRole.fromJson(json['role'] as String),
      studioName: json['studio_name'] as String?,
      studioAddress: json['studio_address'] as String?,
      businessType: json['business_type'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      country: json['country'] as String?,
      state: json['state'] as String?,
      city: json['city'] as String?,
      address: json['address'] as String?,
      bio: json['bio'] as String?,
      specializations: (json['specializations'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      isEmailVerified: json['is_email_verified'] as bool,
      cameraPermissionGranted: json['camera_permission_granted'] as bool,
      photoLibraryPermissionGranted:
          json['photo_library_permission_granted'] as bool,
      pushNotificationsEnabled: json['push_notifications_enabled'] as bool,
      emailNotificationsEnabled:
          json['email_notifications_enabled'] as bool? ?? true,
      allowDownloads: json['allow_downloads'] as bool,
      privateProfile: json['private_profile'] as bool? ?? false,
      appLanguage: json['app_language'] as String? ?? 'English',
      createdAt: DateTime.parse(json['created_at'] as String),
      yearEstablished: json['year_established'] as int?,
      teamSize: json['team_size'] as int?,
      serviceAreas: (json['service_areas'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      studioType: json['studio_type'] as String?,
      experienceYears: json['experience_years'] as int?,
      languages: (json['languages'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      equipmentHighlights: json['equipment_highlights'] as String?,
      pricingMin: (json['pricing_min'] as num?)?.toDouble(),
      pricingMax: (json['pricing_max'] as num?)?.toDouble(),
      packageDetails: json['package_details'] as String?,
      availabilityDays: (json['availability_days'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      instagramUrl: json['instagram_url'] as String?,
      facebookUrl: json['facebook_url'] as String?,
      youtubeUrl: json['youtube_url'] as String?,
      pinterestUrl: json['pinterest_url'] as String?,
      website: json['website'] as String?,
      profilePhotoUrl: json['profile_photo_url'] as String?,
      preferredPhotoTypes: (json['preferred_photo_types'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      subscriptionStatus: json['subscription_status'] as String? ?? 'none',
      currentPlan: json['current_plan'] as String?,
      planStartedAt: _parseUtcTimestamp(json['plan_started_at'] as String?),
      planExpiry: _parseUtcTimestamp(json['plan_expiry'] as String?),
      trialUsed: json['trial_used'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'full_name': fullName,
      'email': email,
      'auth_provider': authProvider,
      'role': role.toJson(),
      'studio_name': studioName,
      'studio_address': studioAddress,
      'business_type': businessType,
      'avatar_url': avatarUrl,
      'cover_image_url': coverImageUrl,
      'country': country,
      'state': state,
      'city': city,
      'address': address,
      'bio': bio,
      'specializations': specializations,
      'is_email_verified': isEmailVerified,
      'camera_permission_granted': cameraPermissionGranted,
      'photo_library_permission_granted': photoLibraryPermissionGranted,
      'push_notifications_enabled': pushNotificationsEnabled,
      'email_notifications_enabled': emailNotificationsEnabled,
      'allow_downloads': allowDownloads,
      'private_profile': privateProfile,
      'app_language': appLanguage,
      'created_at': createdAt.toIso8601String(),
      'year_established': yearEstablished,
      'team_size': teamSize,
      'service_areas': serviceAreas,
      'studio_type': studioType,
      'experience_years': experienceYears,
      'languages': languages,
      'equipment_highlights': equipmentHighlights,
      'pricing_min': pricingMin,
      'pricing_max': pricingMax,
      'package_details': packageDetails,
      'availability_days': availabilityDays,
      'instagram_url': instagramUrl,
      'facebook_url': facebookUrl,
      'youtube_url': youtubeUrl,
      'pinterest_url': pinterestUrl,
      'website': website,
      'profile_photo_url': profilePhotoUrl,
      'preferred_photo_types': preferredPhotoTypes,
      'subscription_status': subscriptionStatus,
      'current_plan': currentPlan,
      'plan_started_at': planStartedAt?.toIso8601String(),
      'plan_expiry': planExpiry?.toIso8601String(),
      'trial_used': trialUsed,
    };
  }

  AppUser copyWith({
    String? id,
    String? fullName,
    String? email,
    String? authProvider,
    AppUserRole? role,
    String? studioName,
    String? studioAddress,
    String? businessType,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    String? coverImageUrl,
    String? country,
    String? state,
    String? city,
    String? address,
    String? bio,
    List<String>? specializations,
    bool? isEmailVerified,
    bool? cameraPermissionGranted,
    bool? photoLibraryPermissionGranted,
    bool? pushNotificationsEnabled,
    bool? emailNotificationsEnabled,
    bool? allowDownloads,
    bool? privateProfile,
    String? appLanguage,
    DateTime? createdAt,
    int? yearEstablished,
    int? teamSize,
    List<String>? serviceAreas,
    String? studioType,
    int? experienceYears,
    List<String>? languages,
    String? equipmentHighlights,
    double? pricingMin,
    double? pricingMax,
    String? packageDetails,
    List<String>? availabilityDays,
    String? instagramUrl,
    String? facebookUrl,
    String? youtubeUrl,
    String? pinterestUrl,
    String? website,
    String? profilePhotoUrl,
    List<String>? preferredPhotoTypes,
    String? subscriptionStatus,
    String? currentPlan,
    DateTime? planStartedAt,
    DateTime? planExpiry,
    bool? trialUsed,
  }) {
    return AppUser(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      authProvider: authProvider ?? this.authProvider,
      role: role ?? this.role,
      studioName: studioName ?? this.studioName,
      studioAddress: studioAddress ?? this.studioAddress,
      businessType: businessType ?? this.businessType,
      avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? this.avatarUrl),
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      country: country ?? this.country,
      state: state ?? this.state,
      city: city ?? this.city,
      address: address ?? this.address,
      bio: bio ?? this.bio,
      specializations: specializations ?? this.specializations,
      isEmailVerified: isEmailVerified ?? this.isEmailVerified,
      cameraPermissionGranted:
          cameraPermissionGranted ?? this.cameraPermissionGranted,
      photoLibraryPermissionGranted:
          photoLibraryPermissionGranted ?? this.photoLibraryPermissionGranted,
      pushNotificationsEnabled:
          pushNotificationsEnabled ?? this.pushNotificationsEnabled,
      emailNotificationsEnabled:
          emailNotificationsEnabled ?? this.emailNotificationsEnabled,
      allowDownloads: allowDownloads ?? this.allowDownloads,
      privateProfile: privateProfile ?? this.privateProfile,
      appLanguage: appLanguage ?? this.appLanguage,
      createdAt: createdAt ?? this.createdAt,
      yearEstablished: yearEstablished ?? this.yearEstablished,
      teamSize: teamSize ?? this.teamSize,
      serviceAreas: serviceAreas ?? this.serviceAreas,
      studioType: studioType ?? this.studioType,
      experienceYears: experienceYears ?? this.experienceYears,
      languages: languages ?? this.languages,
      equipmentHighlights: equipmentHighlights ?? this.equipmentHighlights,
      pricingMin: pricingMin ?? this.pricingMin,
      pricingMax: pricingMax ?? this.pricingMax,
      packageDetails: packageDetails ?? this.packageDetails,
      availabilityDays: availabilityDays ?? this.availabilityDays,
      instagramUrl: instagramUrl ?? this.instagramUrl,
      facebookUrl: facebookUrl ?? this.facebookUrl,
      youtubeUrl: youtubeUrl ?? this.youtubeUrl,
      pinterestUrl: pinterestUrl ?? this.pinterestUrl,
      website: website ?? this.website,
      profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
      preferredPhotoTypes: preferredPhotoTypes ?? this.preferredPhotoTypes,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      currentPlan: currentPlan ?? this.currentPlan,
      planStartedAt: planStartedAt ?? this.planStartedAt,
      planExpiry: planExpiry ?? this.planExpiry,
      trialUsed: trialUsed ?? this.trialUsed,
    );
  }
}

/// Mirrors the backend's `Token` schema — response body of auth endpoints
class AuthToken {
  final String accessToken;
  final String? refreshToken;
  final String tokenType;
  final AppUser user;

  const AuthToken({
    required this.accessToken,
    this.refreshToken,
    required this.tokenType,
    required this.user,
  });

  factory AuthToken.fromJson(Map<String, dynamic> json) {
    return AuthToken(
      accessToken: (json['access_token'] ?? json['access']) as String,
      refreshToken: (json['refresh_token'] ?? json['refresh']) as String?,
      tokenType: json['token_type'] as String? ?? 'bearer',
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      if (refreshToken != null) 'refresh_token': refreshToken,
      'token_type': tokenType,
      'user': user.toJson(),
    };
  }
}
