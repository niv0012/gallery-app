import 'package:dio/dio.dart';

import '../core/utils/app_exceptions.dart';
import '../models/media_model.dart';
import '../storage/media_local_store.dart';
import 'media_repository.dart';

/// Hive-backed [MediaRepository].
///
/// IMPORTANT:
/// - No dummy/seed content.
/// - File operations (copy/move bytes) are NOT performed here; we only
///   update metadata and keep the app offline-safe.
///
/// As of Task 19.13, this class is no longer used directly as "the"
/// repository — it's wrapped by [CachingMediaRepository], which uses it
/// purely as an offline READ cache sitting behind [ApiMediaRepository]:
/// every successful API response gets mirrored in here (via
/// [mirrorFromRemote] / [evictFromCache]), and reads fall back to
/// whatever's cached here when the API is unreachable. The CRUD methods
/// below (createMedia/updateMedia/deleteMedia/etc.) still work exactly
/// as before — they're what [mirrorFromRemote] et al. are built on top
/// of, and what makes this class independently testable and reusable
/// outside of the caching wrapper.
class HiveMediaRepository implements MediaRepository {
  HiveMediaRepository({MediaLocalStore? store})
      : _store = store ?? MediaLocalStore();

  final MediaLocalStore _store;

  (String base, String ext) _nameAndExt(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) {
      return (fileName, '');
    }
    return (fileName.substring(0, dot), fileName.substring(dot));
  }

  String _uniqueFileName({
    required String desiredName,
    required Set<String> existingNames,
  }) {
    final (base, ext) = _nameAndExt(desiredName);

    if (!existingNames.contains(desiredName)) return desiredName;

    var i = 1;
    while (true) {
      final candidate = '$base ($i)$ext';
      if (!existingNames.contains(candidate)) return candidate;
      i++;
    }
  }

  Future<List<MediaModel>> _loadAll() async {
    final list = await _store.load();
    // Keep soft-deleted items in storage but don't return them by default.
    return list;
  }

  Future<void> _saveAll(List<MediaModel> media) async {
    await _store.saveAll(media);
  }

  @override
  Future<MediaPage> fetchMediaPage({
    String? albumId,
    String? folderId,
    bool unfiledOnly = false,
    MediaType? type,
    bool favoritesOnly = false,
    String? likedByClientId,
    int? pageSize,
    String? cursor,
  }) async {
    final list = await fetchMedia(
      albumId: albumId,
      folderId: folderId,
      unfiledOnly: unfiledOnly,
      type: type,
      favoritesOnly: favoritesOnly,
      likedByClientId: likedByClientId,
    );
    return MediaPage(data: list, cursor: null);
  }

  @override
  Future<List<MediaModel>> fetchMedia({
    String? albumId,
    String? folderId,
    bool unfiledOnly = false,
    MediaType? type,
    bool favoritesOnly = false,
    String? likedByClientId,
  }) async {
    final media = await _loadAll();
    Iterable<MediaModel> out = media.where((m) => !m.isDeleted);
    if (unfiledOnly) {
      out = out.where((m) => m.albumId == null && m.folderId == null);
    } else {
      if (albumId != null) out = out.where((m) => m.albumId == albumId);
      if (folderId != null) out = out.where((m) => m.folderId == folderId);
    }
    if (type != null) out = out.where((m) => m.type == type);
    if (favoritesOnly) out = out.where((m) => m.isFavorite);
    // Local repositories don't track client likes; likedByClientId is ignored here.
    return out.toList(growable: false);
  }

  @override
  Future<MediaModel> uploadMedia({
    List<int>? bytes,
    String? filePath,
    Stream<List<int>> Function()? streamData,
    String? webBlobUrl,
    required String fileName,
    required String contentType,
    int sizeBytes = 0,
    String? albumId,
    String? folderId,
    void Function(int sent, int total)? onSendProgress,
    String? existingUploadId,
    String? existingMediaId,
    Map<String, String>? completedParts,
    void Function(String uploadId, String mediaId)? onUploadStarted,
    void Function(int partNumber, String etag)? onPartUploaded,
    CancelToken? cancelToken,
  }) {
    // Hive is a metadata-only cache — it never owned raw file bytes or
    // talked to a network, so "upload" has no meaning here. Callers
    // needing an offline-safe upload should use MediaUploadService
    // (Task 19.5), which queues against the API repository directly.
    throw UnsupportedError(
      'HiveMediaRepository.uploadMedia is not supported — uploads always go through the API repository.',
    );
  }

  @override
  Future<MediaModel> replaceMediaFile({
    required String id,
    List<int>? bytes,
    String? filePath,
    required String fileName,
    required String contentType,
  }) {
    // Same reasoning as uploadMedia: this is a metadata-only cache with
    // no bytes of its own to overwrite, and no server-side pre-edit
    // backup to create. Overwriting a photo's original always goes
    // through the API repository.
    throw UnsupportedError(
      'HiveMediaRepository.replaceMediaFile is not supported — overwriting original files always goes through the API repository.',
    );
  }

  @override
  Future<MediaModel> revertMedia(String id) {
    throw UnsupportedError(
      'HiveMediaRepository.revertMedia is not supported — reverting always goes through the API repository.',
    );
  }

  @override
  Future<MediaModel> createMedia(MediaModel media) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == media.id);
    final now = DateTime.now();

    final toSave = media.copyWith(
      createdAt: media.createdAt == DateTime.fromMillisecondsSinceEpoch(0)
          ? now
          : media.createdAt,
      modifiedAt: now,
    );

    if (idx == -1) {
      all.add(toSave);
    } else {
      // Treat as upsert.
      all[idx] = toSave;
    }

    await _saveAll(all);
    return toSave;
  }

  @override
  Future<MediaModel> updateMedia(MediaModel media) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == media.id);
    if (idx == -1) {
      throw NotFoundException('Media "${media.id}" no longer exists');
    }

    final now = DateTime.now();
    final toSave = media.copyWith(modifiedAt: now);
    all[idx] = toSave;
    await _saveAll(all);
    return toSave;
  }

  @override
  Future<void> deleteMedia(String id) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == id);
    if (idx == -1) throw NotFoundException('Media "$id" no longer exists');

    // Soft delete.
    all[idx] = all[idx].copyWith(isDeleted: true, modifiedAt: DateTime.now());
    await _saveAll(all);
  }

  @override
  Future<void> moveMedia({
    required String id,
    String? albumId,
    String? folderId,
  }) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == id);
    if (idx == -1) throw NotFoundException('Media "$id" no longer exists');

    final updated = all[idx].copyWith(
      albumId: albumId,
      folderId: folderId,
      modifiedAt: DateTime.now(),
    );
    all[idx] = updated;
    await _saveAll(all);
  }

  @override
  Future<MediaModel> copyMedia({
    required String id,
    String? albumId,
    String? folderId,
    DuplicateResolution duplicateResolution = DuplicateResolution.autoRename,
  }) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == id);
    if (idx == -1) throw NotFoundException('Media "$id" no longer exists');

    final source = all[idx];
    final now = DateTime.now();

    // Detect duplicates in the destination album/folder.
    // Since Phase 4 moves/copies are driven by destination albums,
    // this set is the correct scope.
    final existingNames = all
        .where((m) => !m.isDeleted)
        .where((m) => m.albumId == albumId && m.folderId == folderId)
        .map((m) => m.fileName)
        .toSet();

    final String destinationName;
    final bool isDuplicate = existingNames.contains(source.fileName);

    if (isDuplicate && duplicateResolution == DuplicateResolution.skip) {
      // Signal "skipped" by returning the source unchanged.
      // Caller must interpret this via name equality + id difference check.
      return Future.value(source);
    }

    // Default behavior: auto-rename duplicates.
    destinationName = _uniqueFileName(
      desiredName: source.fileName,
      existingNames: existingNames,
    );

    final copied = source.copyWith(
      id: 'me-${now.microsecondsSinceEpoch}',
      albumId: albumId,
      folderId: folderId,
      fileName: destinationName,
      createdAt: now,
      modifiedAt: now,
      isDeleted: false,
    );

    all.add(copied);
    await _saveAll(all);
    return copied;
  }

  @override
  Future<void> toggleFavorite(String id) async {
    final all = await _loadAll();
    final idx = all.indexWhere((m) => m.id == id);
    if (idx == -1) throw NotFoundException('Media "$id" no longer exists');

    final updated = all[idx].copyWith(
      isFavorite: !all[idx].isFavorite,
      modifiedAt: DateTime.now(),
    );
    all[idx] = updated;
    await _saveAll(all);
  }

  @override
  Future<List<MediaModel>> fetchDeletedMedia() async {
    final media = await _loadAll();
    return media.where((m) => m.isDeleted).toList(growable: false);
  }

  @override
  Future<void> permanentlyDeleteMedia(String id) async {
    final all = await _loadAll();
    all.removeWhere((m) => m.id == id);
    await _saveAll(all);
  }

  @override
  Future<void> emptyTrash() async {
    final all = await _loadAll();
    all.removeWhere((m) => m.isDeleted);
    await _saveAll(all);
  }

  @override
  Future<Map<String, int>> fetchMediaCounts() async {
    final all = await _loadAll();
    int photo = 0;
    int video = 0;
    int size = 0;
    for (final m in all) {
      if (m.isDeleted) continue;
      if (m.type == MediaType.photo) photo++;
      if (m.type == MediaType.video) video++;
      size += m.size;
    }
    return {
      'photo_count': photo,
      'video_count': video,
      'total_size_bytes': size,
    };
  }

  // ---------------------------------------------------------------------
  // Cache mirroring (Task 19.13) — used exclusively by
  // [CachingMediaRepository]. These write the given data verbatim, with
  // no timestamp rewriting or existence checks, since the point is to
  // faithfully reflect whatever the API last confirmed rather than
  // apply local-authoring rules like [createMedia]/[updateMedia] do.
  // ---------------------------------------------------------------------

  /// Upserts each item in [media] into the cache by id, byte-for-byte.
  /// Existing cached items whose ids aren't in [media] are left alone —
  /// this is a merge, not a replace, so mirroring a filtered fetch (e.g.
  /// one album) never evicts cached items belonging to other albums.
  Future<void> mirrorFromRemote(Iterable<MediaModel> media) async {
    final all = await _loadAll();
    for (final item in media) {
      final idx = all.indexWhere((m) => m.id == item.id);
      if (idx == -1) {
        all.add(item);
      } else {
        all[idx] = item;
      }
    }
    await _saveAll(all);
  }

  /// Removes [id] from the cache entirely, if present. Used when the API
  /// confirms a hard delete (permanent delete / empty trash), so a
  /// later offline read doesn't keep serving a tombstoned item. A no-op
  /// if [id] isn't cached.
  Future<void> evictFromCache(String id) async {
    final all = await _loadAll();
    all.removeWhere((m) => m.id == id);
    await _saveAll(all);
  }

  // ---------------------------------------------------------------------
  // Per-user cache scoping (Task 19.14) — see [MediaLocalStore] for the
  // actual key-scoping/wipe logic; these just forward to it.
  // ---------------------------------------------------------------------

  /// Scopes the cache to [userId], wiping a previously-cached different
  /// user's entry if this device last cached someone else.
  Future<void> scopeToUser(String userId) => _store.scopeToUser(userId);

  /// Wipes the cache and drops the active user scope. Call on logout.
  Future<void> clearForLogout() => _store.clearForLogout();
}
