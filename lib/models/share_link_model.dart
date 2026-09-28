import 'media_model.dart';

/// Owner-facing share link, mirroring `ShareLinkRead` in
/// `app/schemas/gallery.py` exactly — this is a real row on the server
/// (`app/models/gallery.py`'s `ShareLink`), not a client-only construct.
/// Notably there is no plaintext `password` field anymore: the backend
/// never returns one (it only stores a bcrypt hash), so callers can
/// only ever know [hasPassword], never what it is.
class GalleryShareLink {
  final String id;
  final String? albumId;
  final String? collectionId;
  final String token;
  final String shareUrl;
  final String? clientId;
  final bool hasPassword;
  final DateTime? expiresAt;
  final bool allowDownload;
  final bool showWatermark;
  final bool isRevoked;
  final bool isExpired;
  final bool isActive;

  final int viewsCount;
  final int downloadsCount;
  final DateTime? lastViewedAt;
  final DateTime? lastDownloadedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  const GalleryShareLink({
    required this.id,
    this.albumId,
    this.collectionId,
    required this.token,
    required this.shareUrl,
    this.clientId,
    required this.hasPassword,
    this.expiresAt,
    required this.allowDownload,
    required this.showWatermark,
    required this.isRevoked,
    required this.isExpired,
    required this.isActive,
    this.viewsCount = 0,
    this.downloadsCount = 0,
    this.lastViewedAt,
    this.lastDownloadedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary HTTPS share URL for universal sharing (opens App if installed, Web Gallery if not).
  String get primaryShareUrl =>
      (shareUrl.isNotEmpty && !shareUrl.contains('localhost'))
          ? shareUrl
          : 'https://api.picgallery.in/gallery/$token';

  /// Legacy custom scheme deep link for backward compatibility.
  String get qrDeepLink => 'picgallery://shared/$token';

  factory GalleryShareLink.fromApiJson(Map<String, dynamic> json) {
    final tokenVal = json['token'] as String;
    final rawUrl = json['share_url'] as String?;
    final shareUrlVal =
        (rawUrl != null && rawUrl.isNotEmpty && !rawUrl.contains('localhost'))
            ? rawUrl
            : 'https://api.picgallery.in/gallery/$tokenVal';

    return GalleryShareLink(
      id: json['id'] as String,
      albumId: json['album_id'] as String?,
      collectionId: json['collection_id'] as String?,
      token: tokenVal,
      shareUrl: shareUrlVal,
      clientId: json['client_id'] as String?,
      hasPassword: json['has_password'] as bool? ?? false,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
      allowDownload: json['allow_download'] as bool? ?? true,
      showWatermark: json['show_watermark'] as bool? ?? false,
      isRevoked: json['is_revoked'] as bool? ?? false,
      isExpired: json['is_expired'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      viewsCount: json['views_count'] as int? ?? 0,
      downloadsCount: json['downloads_count'] as int? ?? 0,
      lastViewedAt: json['last_viewed_at'] != null
          ? DateTime.tryParse(json['last_viewed_at'] as String)
          : null,
      lastDownloadedAt: json['last_downloaded_at'] != null
          ? DateTime.tryParse(json['last_downloaded_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Local-storage round-trip pair (used by [ShareLinkLocalStore] to
  /// cache links in Hive), kept separate from [fromApiJson]/the server
  /// wire format. Since [fromApiJson] already tolerates either shape's
  /// null-safe defaults, [fromJson] just delegates to it — the only
  /// real addition here is [toJson], which the API layer never needed
  /// because the app never sends a link back to the server as JSON.
  factory GalleryShareLink.fromJson(Map<String, dynamic> json) =>
      GalleryShareLink.fromApiJson(json);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'album_id': albumId,
      'collection_id': collectionId,
      'token': token,
      'share_url': shareUrl,
      'client_id': clientId,
      'has_password': hasPassword,
      'expires_at': expiresAt?.toIso8601String(),
      'allow_download': allowDownload,
      'show_watermark': showWatermark,
      'is_revoked': isRevoked,
      'is_expired': isExpired,
      'is_active': isActive,
      'views_count': viewsCount,
      'downloads_count': downloadsCount,
      'last_viewed_at': lastViewedAt?.toIso8601String(),
      'last_downloaded_at': lastDownloadedAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

/// Lightweight pre-check, mirrors `ShareLinkStatusRead` — lets the
/// client decide whether to render the passcode gate before fetching
/// (and counting a view for) the full gallery.
class ShareLinkStatus {
  final bool requiresPassword;
  final bool isActive;
  final String? clientId;

  const ShareLinkStatus({
    required this.requiresPassword,
    required this.isActive,
    this.clientId,
  });

  factory ShareLinkStatus.fromApiJson(Map<String, dynamic> json) {
    return ShareLinkStatus(
      requiresPassword: json['requires_password'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? false,
      clientId: json['client_id'] as String?,
    );
  }
}

/// Mirrors `PublicAlbumSummary` — just enough album info for a guest to
/// see, deliberately excluding anything owner-only.
class PublicAlbumSummary {
  final String id;
  final String name;
  final String? description;
  final List<int> gradientArgb;

  const PublicAlbumSummary({
    required this.id,
    required this.name,
    this.description,
    this.gradientArgb = const [0xFF7C5CFF, 0xFFA855F7, 0xFFEC4899],
  });

  factory PublicAlbumSummary.fromApiJson(Map<String, dynamic> json) {
    final rawGradient = json['gradient_argb'] as List<dynamic>?;
    return PublicAlbumSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      gradientArgb: rawGradient != null && rawGradient.length >= 2
          ? rawGradient.map((e) => e as int).toList()
          : const [0xFF7C5CFF, 0xFFA855F7, 0xFFEC4899],
    );
  }
}

class PublicCollectionSummary {
  final String id;
  final String name;

  const PublicCollectionSummary({
    required this.id,
    required this.name,
  });

  factory PublicCollectionSummary.fromApiJson(Map<String, dynamic> json) {
    return PublicCollectionSummary(
      id: json['id'] as String,
      name: json['name'] as String,
    );
  }
}

/// What a client actually sees when viewing a shared gallery — mirrors
/// `PublicShareLinkRead`. No owner_id, no password hash, no internal
/// `id` for the link itself; [token] is the only handle a guest ever
/// needs.
class PublicGalleryData {
  final String token;
  final PublicAlbumSummary? album;
  final PublicCollectionSummary? collection;
  final List<MediaModel>? media;
  final List<PublicAlbumSummary>? albums;
  final bool allowDownload;
  final bool showWatermark;
  final bool requiresPassword;
  final String? studioLogoUrl;

  const PublicGalleryData({
    required this.token,
    this.album,
    this.collection,
    this.media,
    this.albums,
    required this.allowDownload,
    required this.showWatermark,
    required this.requiresPassword,
    this.studioLogoUrl,
  });

  factory PublicGalleryData.fromApiJson(Map<String, dynamic> json) {
    final mediaJson = json['media'] as List<dynamic>?;
    final albumsJson = json['albums'] as List<dynamic>?;
    return PublicGalleryData(
      token: json['token'] as String,
      album: json['album'] != null
          ? PublicAlbumSummary.fromApiJson(json['album'] as Map<String, dynamic>)
          : null,
      collection: json['collection'] != null
          ? PublicCollectionSummary.fromApiJson(json['collection'] as Map<String, dynamic>)
          : null,
      media: mediaJson
          ?.map((e) => MediaModel.fromApiJson(e as Map<String, dynamic>))
          .toList(),
      albums: albumsJson
          ?.map((e) => PublicAlbumSummary.fromApiJson(e as Map<String, dynamic>))
          .toList(),
      allowDownload: json['allow_download'] as bool? ?? true,
      showWatermark: json['show_watermark'] as bool? ?? false,
      requiresPassword: json['requires_password'] as bool? ?? false,
      studioLogoUrl: json['studio_logo_url'] as String?,
    );
  }
}
