import 'package:dio/dio.dart';

import '../core/network/api_client.dart';
import '../core/utils/app_exceptions.dart';
import '../models/media_model.dart';
import '../services/media_upload_service.dart';
import '../services/chunked_upload_service.dart';
import 'media_repository.dart';

/// API-backed [MediaRepository], talking to `app/api/routes/media.py`
/// (`GET/PATCH/DELETE /media` + friends) via [ApiClient], the same way
/// [UserRepository]/[AuthRepository] do for their routers.
///
/// [uploadMedia] is the one exception — it's real multipart file upload
/// (`POST /media/upload`), not JSON, so it's delegated straight to
/// [MediaUploadService] (Task 19.5) instead of going through
/// [ApiClient].
///
/// A few [MediaRepository] members have no server-side equivalent at
/// all (there's no "create metadata-only media" route) — those throw
/// [UnsupportedError] with a pointer to the right alternative, same
/// pattern [HiveMediaRepository] already uses for its own unsupported
/// [uploadMedia]. [copyMedia] used to be one of these but now maps to
/// `POST /media/{id}/copy`, a real server-side file copy.
class ApiMediaRepository implements MediaRepository {
  ApiMediaRepository(
      {required ApiClient apiClient,
      MediaUploadService? uploadService,
      ChunkedUploadService? chunkedUploadService})
      : _apiClient = apiClient,
        _uploadService =
            uploadService ?? MediaUploadService(apiClient: apiClient),
        _chunkedUploadService =
            chunkedUploadService ?? ChunkedUploadService(apiClient: apiClient);

  final ApiClient _apiClient;
  final MediaUploadService _uploadService;
  final ChunkedUploadService _chunkedUploadService;
  static const int _chunkedUploadThresholdBytes = 50 * 1024 * 1024;

  List<MediaModel> _mapList(dynamic json) {
    final list = json as List<dynamic>;
    return list
        .map((e) => MediaModel.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<MediaModel> _getOne(String id) async {
    try {
      final json = await _apiClient.get('/media/$id');
      return MediaModel.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
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
    final query = <String, String>{
      if (unfiledOnly) 'unfiled_only': 'true',
      if (!unfiledOnly && albumId != null) 'album_id': albumId,
      if (!unfiledOnly && folderId != null) 'folder_id': folderId,
      if (type != null) 'media_type': type.name,
      if (favoritesOnly) 'favorites_only': 'true',
      if (likedByClientId != null) 'liked_by_client_id': likedByClientId,
    };
    final path = query.isEmpty
        ? '/media'
        : '/media?${Uri(queryParameters: query).query}';
    final json = await _apiClient.get(path, receiveTimeout: const Duration(seconds: 30));
    return _mapList(json);
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
    final query = <String, String>{
      if (unfiledOnly) 'unfiled_only': 'true',
      if (!unfiledOnly && albumId != null) 'album_id': albumId,
      if (!unfiledOnly && folderId != null) 'folder_id': folderId,
      if (type != null) 'media_type': type.name,
      if (favoritesOnly) 'favorites_only': 'true',
      if (likedByClientId != null) 'liked_by_client_id': likedByClientId,
      if (pageSize != null) 'page_size': pageSize.toString(),
      if (cursor != null) 'cursor': cursor,
    };
    final path = query.isEmpty
        ? '/media/page'
        : '/media/page?${Uri(queryParameters: query).query}';
    final json = await _apiClient.get(path, receiveTimeout: const Duration(seconds: 30));
    final map = json as Map<String, dynamic>;
    return MediaPage(
      data: _mapList(map['items']),
      cursor: map['next_cursor'] as String?,
    );
  }

  @override
  Future<MediaModel> createMedia(MediaModel media) {
    // The backend has no "insert media metadata with no file" route —
    // `POST /media/upload` always requires real bytes. Callers wanting
    // to add a new item against the API repository must go through
    // [uploadMedia] instead.
    throw UnsupportedError(
      'ApiMediaRepository.createMedia is not supported — use uploadMedia() '
      'to create media backed by the API, since POST /media/upload always '
      'requires real file bytes.',
    );
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
    if (filePath != null &&
        filePath.isNotEmpty &&
        sizeBytes >= _chunkedUploadThresholdBytes) {
      return _chunkedUploadService.uploadChunked(
        filePath: filePath,
        fileName: fileName,
        contentType: contentType,
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
    }

    return _uploadService.upload(
      bytes: bytes,
      filePath: filePath,
      streamData: streamData,
      webBlobUrl: webBlobUrl,
      fileName: fileName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      albumId: albumId,
      folderId: folderId,
      onSendProgress: onSendProgress,
    );
  }

  @override
  Future<MediaModel> updateMedia(MediaModel media) async {
    // Stateless per call — fetch the server's current copy first so we
    // only send the fields that actually changed, and so a restore
    // (isDeleted true -> false) can be routed to the dedicated
    // POST /media/{id}/restore endpoint instead of PATCH, which has no
    // `is_deleted` field at all.
    final current = await _getOne(media.id);

    MediaModel result = current;

    if (current.isDeleted && !media.isDeleted) {
      final json = await _apiClient.post('/media/${media.id}/restore');
      result = MediaModel.fromApiJson(json as Map<String, dynamic>);
    }

    final recipeChanged = media.editRecipe?.toJson().toString() !=
        result.editRecipe?.toJson().toString();

    final body = media.toUpdateJson(
      albumId: media.albumId != result.albumId ? media.albumId : null,
      clearAlbum: media.albumId == null && result.albumId != null,
      folderId: media.folderId != result.folderId ? media.folderId : null,
      clearFolder: media.folderId == null && result.folderId != null,
      isFavorite:
          media.isFavorite != result.isFavorite ? media.isFavorite : null,
      fileName: media.fileName != result.fileName ? media.fileName : null,
      editRecipe: recipeChanged ? media.editRecipe : null,
      clearEditRecipe: recipeChanged && media.editRecipe == null,
    );

    if (body.isEmpty) return result;

    final json = await _apiClient.patch('/media/${media.id}', body: body);
    return MediaModel.fromApiJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> deleteMedia(String id) async {
    try {
      await _apiClient.delete('/media/$id');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<void> moveMedia({
    required String id,
    String? albumId,
    String? folderId,
  }) async {
    final body = <String, dynamic>{
      if (albumId != null) 'album_id': albumId else 'clear_album': true,
      if (folderId != null) 'folder_id': folderId else 'clear_folder': true,
    };
    try {
      await _apiClient.patch('/media/$id', body: body);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<MediaModel> copyMedia({
    required String id,
    String? albumId,
    String? folderId,
    DuplicateResolution duplicateResolution = DuplicateResolution.autoRename,
  }) async {
    // Server-side copy (`POST /media/{id}/copy`): the backend copies the
    // original + thumbnail file on disk and inserts the new row, so this
    // never has to pull the full bytes down to the client just to push
    // them back up again — important for large videos.
    final query = <String, String>{
      if (albumId != null) 'album_id': albumId,
      if (folderId != null) 'folder_id': folderId,
      'duplicate_resolution': duplicateResolution == DuplicateResolution.skip
          ? 'skip'
          : 'auto_rename',
    };
    final path = '/media/$id/copy?${Uri(queryParameters: query).query}';
    try {
      final json = await _apiClient.post(path);
      return MediaModel.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<void> toggleFavorite(String id) async {
    final current = await _getOne(id);
    try {
      await _apiClient.patch(
        '/media/$id',
        body: {'is_favorite': !current.isFavorite},
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<MediaModel> replaceMediaFile({
    required String id,
    List<int>? bytes,
    String? filePath,
    required String fileName,
    required String contentType,
  }) async {
    try {
      return await _uploadService.replaceFile(
        mediaId: id,
        bytes: bytes,
        filePath: filePath,
        fileName: fileName,
        contentType: contentType,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<MediaModel> revertMedia(String id) async {
    try {
      final json = await _apiClient.post('/media/$id/revert');
      return MediaModel.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<List<MediaModel>> fetchDeletedMedia() async {
    final json = await _apiClient.get('/media?trashed=true');
    return _mapList(json);
  }

  @override
  Future<void> permanentlyDeleteMedia(String id) async {
    try {
      await _apiClient.delete('/media/$id/permanent');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Media "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<void> emptyTrash() async {
    await _apiClient.delete('/media/trash/empty');
  }

  @override
  Future<Map<String, int>> fetchMediaCounts() async {
    final json = await _apiClient.get('/media/counts');
    return {
      'photo_count': (json['total_photos'] ?? json['photo_count']) as int? ?? 0,
      'video_count': (json['total_videos'] ?? json['video_count']) as int? ?? 0,
      'total_size_bytes': json['total_size_bytes'] as int? ?? 0,
    };
  }
}
