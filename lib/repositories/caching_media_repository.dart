import 'package:dio/dio.dart';

import '../core/network/api_client.dart';
import '../models/media_model.dart';
import 'api_media_repository.dart';
import 'hive_media_repository.dart';
import 'media_repository.dart';

/// Decorates [ApiMediaRepository] with a [HiveMediaRepository]-backed
/// offline READ cache (Task 19.13).
///
/// This is deliberately NOT a write-behind sync engine — mutations
/// (create/update/delete/move/copy/favorite/etc.) always go straight to
/// the API and fail exactly as they always did when there's no
/// connection. Offline *uploads* already have their own dedicated queue
/// (`MediaUploadService` / `UploadQueueProvider`, Task 19.5+) and that's
/// the right place for retry/replay logic, not here.
///
/// What this class DOES do:
/// - On every successful [fetchMedia] / [fetchDeletedMedia], mirror the
///   results into the Hive cache (merged by id, not a wholesale
///   replace — see [HiveMediaRepository.mirrorFromRemote]).
/// - On every successful mutation, best-effort mirror its effect into
///   the cache too, so the cache doesn't go stale between fetches (e.g.
///   toggling a favorite while online should still show as favorited
///   the next time you open the app with no signal).
/// - When the API is unreachable — [ApiClient] turns every network-level
///   failure (connection refused, DNS failure, timeout) into
///   `ApiException(0, ...)`, see `ApiClient._guarded` / `_throwTimeout`
///   — [fetchMedia] / [fetchDeletedMedia] fall back to serving whatever
///   is cached, read-only. Any other error (404, 422, 500, etc.) is a
///   real API error and is rethrown as-is; only "couldn't reach the
///   server" triggers the fallback.
class CachingMediaRepository implements MediaRepository {
  CachingMediaRepository({
    required ApiMediaRepository api,
    HiveMediaRepository? cache,
  })  : _api = api,
        _cache = cache ?? HiveMediaRepository();

  final ApiMediaRepository _api;
  final HiveMediaRepository _cache;

  bool _isUnreachable(Object error) =>
      error is ApiException && error.statusCode == 0;

  /// Cache writes are best-effort: a caching failure (e.g. Hive not yet
  /// initialized on some odd platform) must never mask a successful API
  /// call, so every mirror/evict call goes through here.
  Future<void> _bestEffort(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {
      // Swallow — the cache is a convenience, not a source of truth.
    }
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
    try {
      final page = await _api.fetchMediaPage(
        albumId: albumId,
        folderId: folderId,
        unfiledOnly: unfiledOnly,
        type: type,
        favoritesOnly: favoritesOnly,
        likedByClientId: likedByClientId,
        pageSize: pageSize,
        cursor: cursor,
      );
      // We still mirror the results into the cache.
      await _bestEffort(() => _cache.mirrorFromRemote(page.data));
      return page;
    } catch (e) {
      if (_isUnreachable(e)) {
        // If unreachable, fallback to full fetchMedia since cache doesn't support pagination
        final fallbackList = await _cache.fetchMedia(
          albumId: albumId,
          folderId: folderId,
          unfiledOnly: unfiledOnly,
          type: type,
          favoritesOnly: favoritesOnly,
          likedByClientId: likedByClientId,
        );
        return MediaPage(data: fallbackList, cursor: null);
      }
      rethrow;
    }
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
    try {
      final media = await _api.fetchMedia(
        albumId: albumId,
        folderId: folderId,
        unfiledOnly: unfiledOnly,
        type: type,
        favoritesOnly: favoritesOnly,
        likedByClientId: likedByClientId,
      );
      await _bestEffort(() => _cache.mirrorFromRemote(media));
      return media;
    } catch (e) {
      if (!_isUnreachable(e)) rethrow;
      // No connection — serve read-only from the last known cache.
      return _cache.fetchMedia(
        albumId: albumId,
        folderId: folderId,
        unfiledOnly: unfiledOnly,
        type: type,
        favoritesOnly: favoritesOnly,
        likedByClientId: likedByClientId,
      );
    }
  }

  @override
  Future<List<MediaModel>> fetchDeletedMedia() async {
    try {
      final media = await _api.fetchDeletedMedia();
      await _bestEffort(() => _cache.mirrorFromRemote(media));
      return media;
    } catch (e) {
      if (!_isUnreachable(e)) rethrow;
      return _cache.fetchDeletedMedia();
    }
  }

  @override
  Future<MediaModel> createMedia(MediaModel media) {
    // Unsupported on the API side (see ApiMediaRepository.createMedia) —
    // nothing to mirror since this always throws.
    return _api.createMedia(media);
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
  }) async {
    final result = await _api.uploadMedia(
      bytes: bytes,
      filePath: filePath,
      streamData: streamData,
      webBlobUrl: webBlobUrl,
      fileName: fileName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      albumId: albumId,
      folderId: folderId,
      existingUploadId: existingUploadId,
      existingMediaId: existingMediaId,
      completedParts: completedParts,
      onUploadStarted: onUploadStarted,
      onPartUploaded: onPartUploaded,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
    await _bestEffort(() => _cache.mirrorFromRemote([result]));
    return result;
  }

  @override
  Future<MediaModel> updateMedia(MediaModel media) async {
    final result = await _api.updateMedia(media);
    await _bestEffort(() => _cache.mirrorFromRemote([result]));
    return result;
  }

  @override
  Future<void> deleteMedia(String id) async {
    await _api.deleteMedia(id);
    // Soft delete — API has no return value, so mirror via the cache's
    // own soft-delete logic (best-effort: fine if it isn't cached yet).
    await _bestEffort(() => _cache.deleteMedia(id));
  }

  @override
  Future<void> moveMedia({
    required String id,
    String? albumId,
    String? folderId,
  }) async {
    await _api.moveMedia(id: id, albumId: albumId, folderId: folderId);
    await _bestEffort(
      () => _cache.moveMedia(id: id, albumId: albumId, folderId: folderId),
    );
  }

  @override
  Future<MediaModel> copyMedia({
    required String id,
    String? albumId,
    String? folderId,
    DuplicateResolution duplicateResolution = DuplicateResolution.autoRename,
  }) async {
    final result = await _api.copyMedia(
      id: id,
      albumId: albumId,
      folderId: folderId,
      duplicateResolution: duplicateResolution,
    );
    await _bestEffort(() => _cache.mirrorFromRemote([result]));
    return result;
  }

  @override
  Future<MediaModel> replaceMediaFile({
    required String id,
    List<int>? bytes,
    String? filePath,
    required String fileName,
    required String contentType,
  }) async {
    final result = await _api.replaceMediaFile(
      id: id,
      bytes: bytes,
      filePath: filePath,
      fileName: fileName,
      contentType: contentType,
    );
    await _bestEffort(() => _cache.mirrorFromRemote([result]));
    return result;
  }

  @override
  Future<MediaModel> revertMedia(String id) async {
    final result = await _api.revertMedia(id);
    await _bestEffort(() => _cache.mirrorFromRemote([result]));
    return result;
  }

  @override
  Future<void> toggleFavorite(String id) async {
    await _api.toggleFavorite(id);
    // API has no return value here either — flip the cached copy's flag
    // to match, best-effort.
    await _bestEffort(() => _cache.toggleFavorite(id));
  }

  @override
  Future<void> permanentlyDeleteMedia(String id) async {
    await _api.permanentlyDeleteMedia(id);
    await _bestEffort(() => _cache.evictFromCache(id));
  }

  @override
  Future<void> emptyTrash() async {
    await _api.emptyTrash();
    await _bestEffort(() => _cache.emptyTrash());
  }

  @override
  Future<Map<String, int>> fetchMediaCounts() async {
    return _api.fetchMediaCounts();
  }

  // ---------------------------------------------------------------------
  // Per-user cache scoping (Task 19.14)
  // ---------------------------------------------------------------------

  /// Scopes the Hive offline cache to [userId] — see
  /// [HiveMediaRepository.scopeToUser] / [MediaLocalStore.scopeToUser].
  /// Called by [mediaRepositoryProvider] whenever the signed-in user
  /// becomes known or changes (login, restored session, or switching
  /// accounts without an intervening logout).
  Future<void> scopeCacheToUser(String userId) =>
      _bestEffort(() => _cache.scopeToUser(userId));

  /// Wipes the Hive offline cache — see
  /// [HiveMediaRepository.clearForLogout]. Called by
  /// [mediaRepositoryProvider] on logout.
  Future<void> clearCacheForLogout() =>
      _bestEffort(() => _cache.clearForLogout());
}
