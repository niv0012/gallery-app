import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/media_model.dart';
import '../models/edit_recipe.dart';

/// Hive-backed local persistence for Media (photos/videos).
///
/// IMPORTANT:
/// - This stores a single JSON blob for the whole media library (same
///   approach as [DashboardLocalStore]) to keep the first Phase small and
///   architecture-compatible.
/// - No dummy data: the initial persisted state is empty.
///
/// Task 19.14 — the box (`media_box`) is shared by every account that's
/// ever signed in on this device, so the JSON blob's *key* is scoped by
/// user id (`media_state_v1:<userId>`) rather than being one fixed key.
/// Callers MUST call [scopeToUser] with the current user's id before
/// [load]/[saveAll] do anything meaningful — until then this store has
/// no active scope and [load]/[saveAll] are no-ops, so a caller that
/// forgets to scope it fails safe (reads nothing / writes nothing)
/// instead of accidentally reading or writing under a shared/global key.
class MediaLocalStore {
  static const String _boxName = 'media_box';
  static const String _stateKeyPrefix = 'media_state_v1';
  static const String _lastUserIdKey = 'media_state_v1_last_user_id';

  Box<String>? _box;
  bool _initialized = false;

  /// The user this store is currently scoped to. `null` means "no
  /// active scope" — see class doc.
  String? _userId;

  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
    _initialized = true;
  }

  String _keyFor(String userId) => '$_stateKeyPrefix:$userId';

  /// Scopes this store to [userId]'s own cache entry.
  ///
  /// If a *different* user was cached last on this device (tracked via
  /// [_lastUserIdKey], a small marker stored in the same box), that
  /// previous user's entry is deleted outright — not just left
  /// unreachable under a different key — so switching accounts never
  /// leaves the previous person's cached media sitting on disk. This is
  /// the "reset the cache on login if the incoming user id differs"
  /// half of Task 19.14; [clearForLogout] is the other half.
  ///
  /// Also defensively deletes any pre-19.14 unscoped blob (the old
  /// fixed `media_state_v1` key), so it can never surface under
  /// whichever account happens to log in first after this upgrade.
  ///
  /// A no-op (besides re-affirming the marker) if [userId] is already
  /// the last-scoped user.
  Future<void> scopeToUser(String userId) async {
    if (!_initialized) await init();

    final lastUserId = _box?.get(_lastUserIdKey);
    if (lastUserId != null && lastUserId != userId) {
      await _box?.delete(_keyFor(lastUserId));
    }
    await _box?.delete(_stateKeyPrefix); // pre-19.14 unscoped leftovers

    _userId = userId;
    await _box?.put(_lastUserIdKey, userId);
  }

  /// Clears this device's cached media entirely and drops the active
  /// scope. Call on logout so a signed-out app never has any account's
  /// cached media reachable, and so the very next login — whoever it's
  /// for — can't accidentally inherit a session that already ended.
  Future<void> clearForLogout() async {
    if (!_initialized) await init();

    final uid = _userId ?? _box?.get(_lastUserIdKey);
    if (uid != null) {
      await _box?.delete(_keyFor(uid));
    }
    await _box?.delete(_lastUserIdKey);
    _userId = null;
  }

  Future<List<MediaModel>> load() async {
    if (!_initialized) await init();
    final uid = _userId;
    if (uid == null) return <MediaModel>[];

    final raw = _box?.get(_keyFor(uid));
    if (raw == null || raw.isEmpty) return <MediaModel>[];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return <MediaModel>[];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map((e) => _mediaFromJson(e))
        .toList();
  }

  Future<void> saveAll(List<MediaModel> media) async {
    if (!_initialized) await init();
    final uid = _userId;
    if (uid == null) return;

    final json = media.map(_mediaToJson).toList();
    await _box?.put(_keyFor(uid), jsonEncode(json));
  }

  Future<void> clear() async {
    if (!_initialized) await init();
    final uid = _userId;
    if (uid == null) return;
    await _box?.delete(_keyFor(uid));
  }

  // ---------------------------------------------------------------------
  // JSON helpers
  // ---------------------------------------------------------------------

  Map<String, dynamic> _mediaToJson(MediaModel m) {
    return {
      'id': m.id,
      'type': m.type.name,
      'filePath': m.filePath,
      'thumbnailPath': m.thumbnailPath,
      'fileName': m.fileName,
      'albumId': m.albumId,
      'folderId': m.folderId,
      'size': m.size,
      'width': m.width,
      'height': m.height,
      'durationMillis': m.duration?.inMilliseconds,
      'createdAt': m.createdAt.toIso8601String(),
      'modifiedAt': m.modifiedAt.toIso8601String(),
      'isFavorite': m.isFavorite,
      'isDeleted': m.isDeleted,
      'gradientArgb': m.gradientArgb,
      'editRecipe': m.editRecipe?.toJson(),
      // Server URLs must survive the offline cache. Without them a cached
      // API video has no filePath AND no remoteUrl, so the player shows
      // "Video file not available on this device".
      'remoteUrl': m.remoteUrl,
      'remoteThumbnailUrl': m.remoteThumbnailUrl,
      'likeCount': m.likeCount,
      'isLikedByMe': m.isLikedByMe,
      'commentCount': m.commentCount,
      'canRevert': m.canRevert,
    };
  }

  MediaModel _mediaFromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? MediaType.photo.name;
    final type = MediaType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => MediaType.photo,
    );

    final durationMillis = json['durationMillis'];
    final duration = durationMillis is int
        ? Duration(milliseconds: durationMillis)
        : (durationMillis == null ? null : null);

    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final modifiedAt = DateTime.tryParse(json['modifiedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return MediaModel(
      id: json['id'] as String,
      type: type,
      filePath: json['filePath'] as String? ?? '',
      thumbnailPath: json['thumbnailPath'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      albumId: json['albumId'] as String?,
      folderId: json['folderId'] as String?,
      size: json['size'] as int? ?? 0,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      duration: duration,
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      isFavorite: json['isFavorite'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      gradientArgb: (json['gradientArgb'] as List?)?.cast<int>() ??
          const [
            0xFF7C5CFF,
            0xFFA855F7,
            0xFFEC4899,
          ],
      editRecipe: json['editRecipe'] != null
          ? EditRecipe.fromJson(json['editRecipe'] as Map<String, dynamic>)
          : null,
      remoteUrl: json['remoteUrl'] as String?,
      remoteThumbnailUrl: json['remoteThumbnailUrl'] as String?,
      likeCount: json['likeCount'] as int? ?? 0,
      isLikedByMe: json['isLikedByMe'] as bool? ?? false,
      commentCount: json['commentCount'] as int? ?? 0,
      canRevert: json['canRevert'] as bool? ?? false,
    );
  }
}
