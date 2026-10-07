import 'dart:ui';

import '../core/theme/app_theme.dart';

/// Album entity used by the Albums List screen.
///
/// Note: cover image is represented by a placeholder only (no files/URLs,
/// no network). Everything is kept in-memory and dynamic.
class AlbumModel {
  final String id;
  final String name;
  final String? description;

  /// When the album was first created — used for Album Statistics
  /// ("created this month", etc.) and is independent from [updatedAt].
  final DateTime createdAt;

  /// Soft deletion timestamp. Null if active.
  final DateTime? deletedAt;

  /// Used to compute "Recent Albums".
  final DateTime updatedAt;

  /// Photo + video counts.
  final int photoCount;
  final int videoCount;

  /// Count of distinct folders that contain media (photos/videos)
  /// linked to this album.
  final int folderCount;

  final int displayOrder;

  /// User favorite toggle.
  final bool isFavorite;

  /// The folder this album is filed under, or `null` when it sits at
  /// the top level ("unfiled"). This is the real link used for Folder
  /// filtering, Folder Details' album preview, and Folder Statistics —
  /// it replaces any position-based approximation.
  final String? folderId;

  /// Visual identity.
  final List<Color> gradient;

  /// Servable URL for the most-recently-added active media item in this
  /// album (see `AlbumRead.cover_thumbnail_url` on the backend). Null
  /// for empty albums or when loaded from the local Hive cache — in
  /// either case callers should fall back to [gradient].
  final String? coverThumbnailUrl;

  /// Owning studio's identity — only set when this [AlbumModel] was
  /// built from `ConnectedAlbumRead` (`GET /albums/shared-with-me`),
  /// i.e. a client's cross-studio "connected" view. `null` for a
  /// studio-owner's own albums (`AlbumRead`), where the album's owner
  /// is implicitly "me" and doesn't need to be carried per-album.
  final String? studioId;
  final String? studioName;
  final String? studioAvatarUrl;

  /// True when this album also has an active, password-protected public
  /// share link (`ConnectedAlbumRead.has_protected_share_link`, Task
  /// 21.24). Only ever set on the connected/shared view — a studio's own
  /// [fromApiJson] albums don't carry this. Purely informational: it
  /// never means *this* client needs a password, since their own access
  /// is already granted directly (see 21.23's audit).
  final bool hasProtectedShareLink;

  /// True when the studio enabled their logo watermark for this album
  /// (`ConnectedAlbumRead.show_watermark`). Only set on connected/shared view
  /// albums. When true, [studioAvatarUrl] is overlaid as a corner watermark
  /// when the client opens a photo or video from this album.
  final bool showWatermark;

  AlbumModel({
    required this.id,
    required this.name,
    this.description,
    DateTime? createdAt,
    required this.updatedAt,
    required this.photoCount,
    required this.videoCount,
    required this.folderCount,
    this.displayOrder = 0,
    this.isFavorite = false,
    this.folderId,
    List<Color>? gradient,
    this.coverThumbnailUrl,
    this.studioId,
    this.studioName,
    this.studioAvatarUrl,
    this.hasProtectedShareLink = false,
    this.showWatermark = false,
    this.deletedAt,
  })  : createdAt = createdAt ?? updatedAt,
        gradient = gradient ??
            const [
              AppColors.primary,
              AppColors.secondary,
              AppColors.accent,
            ];

  /// Builds an [AlbumModel] from a `GET/POST/PATCH /albums` response
  /// body (`AlbumRead` in `app/schemas/gallery.py`). Field names below
  /// mirror the backend's snake_case JSON exactly.
  factory AlbumModel.fromApiJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      photoCount: json['photo_count'] as int? ?? 0,
      videoCount: json['video_count'] as int? ?? 0,
      folderCount: json['folder_count'] as int? ?? 0,
      displayOrder: json['display_order'] as int? ?? 0,
      isFavorite: json['is_favorite'] as bool? ?? false,
      folderId: json['folder_id'] as String?,
      gradient: _gradientFromArgb(
        (json['gradient_argb'] as List<dynamic>?)?.cast<int>(),
      ),
      coverThumbnailUrl: json['cover_thumbnail_url'] as String?,
      deletedAt: json['deleted_at'] != null ? DateTime.parse(json['deleted_at'] as String) : null,
    );
  }

  /// Builds an [AlbumModel] from a `GET /albums/shared-with-me` response
  /// entry (`ConnectedAlbumRead` in `app/schemas/gallery.py`). Same album
  /// fields as [fromApiJson] minus `folder_id`/`folder_count` (a studio's
  /// folder structure is private, not shared with a connected client —
  /// both default to "unfiled"), plus the owning studio's identity so
  /// cards spanning multiple connected studios can say whose album it is.
  factory AlbumModel.fromConnectedApiJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      photoCount: json['photo_count'] as int? ?? 0,
      videoCount: json['video_count'] as int? ?? 0,
      folderCount: 0,
      displayOrder: json['display_order'] as int? ?? 0,
      isFavorite: json['is_favorite'] as bool? ?? false,
      folderId: null,
      gradient: _gradientFromArgb(
        (json['gradient_argb'] as List<dynamic>?)?.cast<int>(),
      ),
      coverThumbnailUrl: json['cover_thumbnail_url'] as String?,
      studioId: json['studio_id'] as String,
      studioName: json['studio_name'] as String?,
      studioAvatarUrl: json['studio_avatar_url'] as String?,
      hasProtectedShareLink: json['has_protected_share_link'] as bool? ?? false,
      showWatermark: json['show_watermark'] as bool? ?? false,
      deletedAt: json['deleted_at'] != null ? DateTime.parse(json['deleted_at'] as String) : null,
    );
  }

  static List<Color> _gradientFromArgb(List<int>? argb) {
    if (argb == null || argb.isEmpty) {
      return const [AppColors.primary, AppColors.secondary, AppColors.accent];
    }
    return argb.map(Color.new).toList(growable: false);
  }

  /// Body for `POST /albums` (`AlbumCreate`). Omits everything the
  /// backend computes itself (id, counts, timestamps, display_order).
  Map<String, dynamic> toCreateJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (folderId != null) 'folder_id': folderId,
        'gradient_argb': gradient.map((c) => c.toARGB32()).toList(),
      };

  /// Body for `PATCH /albums/{id}` (`AlbumUpdate`). Every field is
  /// included on every save — the backend only touches keys that are
  /// present (`exclude_unset=True`), so intentionally-null fields must
  /// be signaled via the explicit `clear_*` flags rather than omission.
  Map<String, dynamic> toUpdateJson(
          {bool clearDescription = false, bool clearFolder = false}) =>
      {
        'name': name,
        'description': description,
        'clear_description': clearDescription,
        'folder_id': folderId,
        'clear_folder': clearFolder,
        'is_favorite': isFavorite,
        'display_order': displayOrder,
        'gradient_argb': gradient.map((c) => c.toARGB32()).toList(),
      };

  /// Deserializes from a plain JSON map (Hive-local store format).
  /// Uses camelCase keys matching [toJson] output.
  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      photoCount: json['photoCount'] as int? ?? 0,
      videoCount: json['videoCount'] as int? ?? 0,
      folderCount: json['folderCount'] as int? ?? 0,
      displayOrder: json['displayOrder'] as int? ?? 0,
      isFavorite: json['isFavorite'] as bool? ?? false,
      folderId: json['folderId'] as String?,
      gradient: _gradientFromArgb(
        (json['gradientArgb'] as List<dynamic>?)?.cast<int>(),
      ),
      deletedAt: json['deletedAt'] != null ? DateTime.parse(json['deletedAt'] as String) : null,
    );
  }

  /// Serializes to a plain JSON map (Hive-local store format).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'photoCount': photoCount,
        'videoCount': videoCount,
        'folderCount': folderCount,
        'displayOrder': displayOrder,
        'isFavorite': isFavorite,
        'folderId': folderId,
        'gradientArgb': gradient.map((c) => c.toARGB32()).toList(),
        'deletedAt': deletedAt?.toIso8601String(),
      };

  AlbumModel copyWith({
    String? id,
    String? name,
    String? description,
    bool clearDescription = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? photoCount,
    int? videoCount,
    int? folderCount,
    int? displayOrder,
    bool? isFavorite,
    String? folderId,
    bool clearFolder = false,
    List<Color>? gradient,
    String? coverThumbnailUrl,
    String? studioId,
    String? studioName,
    String? studioAvatarUrl,
    bool? hasProtectedShareLink,
    DateTime? deletedAt,
  }) {
    return AlbumModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: clearDescription ? null : (description ?? this.description),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      photoCount: photoCount ?? this.photoCount,
      videoCount: videoCount ?? this.videoCount,
      folderCount: folderCount ?? this.folderCount,
      displayOrder: displayOrder ?? this.displayOrder,
      isFavorite: isFavorite ?? this.isFavorite,
      folderId: clearFolder ? null : (folderId ?? this.folderId),
      gradient: gradient ?? this.gradient,
      coverThumbnailUrl: coverThumbnailUrl ?? this.coverThumbnailUrl,
      studioId: studioId ?? this.studioId,
      studioName: studioName ?? this.studioName,
      studioAvatarUrl: studioAvatarUrl ?? this.studioAvatarUrl,
      hasProtectedShareLink:
          hasProtectedShareLink ?? this.hasProtectedShareLink,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
