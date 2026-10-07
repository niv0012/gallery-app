import '../core/network/api_client.dart';
import '../core/utils/app_exceptions.dart';
import '../models/album_model.dart';
import '../models/delete_preview_model.dart';
import '../models/trash_item.dart';

abstract class AlbumRepository {
  Future<List<AlbumModel>> fetchAlbums();

  /// Persists a brand-new album and returns the stored copy.
  Future<AlbumModel> createAlbum(AlbumModel album);

  /// Persists changes to an existing album (matched by [AlbumModel.id])
  /// and returns the stored copy. Throws [NotFoundException] if the
  /// album no longer exists.
  Future<AlbumModel> updateAlbum(AlbumModel album);

  /// Removes an album. Throws [NotFoundException] if it no longer exists.
  Future<void> deleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp});

  Future<DeletePreviewResponse> previewDeleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp});
  
  Future<List<TrashedAlbumItem>> fetchDeletedAlbums();
  Future<void> restoreAlbum(String id);
}


/// API-backed [AlbumRepository], talking to `app/api/routes/albums.py`
/// (`GET/POST/PATCH/DELETE /albums`) via [ApiClient].
///
/// Every album/folder created against this repository is a real row on
/// the server, with a real server-generated UUID `id`.
class ApiAlbumRepository implements AlbumRepository {
  ApiAlbumRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  List<AlbumModel> _mapList(dynamic json) {
    final list = json as List<dynamic>;
    return list
        .map((e) => AlbumModel.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<List<AlbumModel>> fetchAlbums() async {
    final json = await _apiClient.get('/albums', receiveTimeout: const Duration(seconds: 30));
    return _mapList(json);
  }

  @override
  Future<AlbumModel> createAlbum(AlbumModel album) async {
    final json = await _apiClient.post('/albums', body: album.toCreateJson());
    return AlbumModel.fromApiJson(json as Map<String, dynamic>);
  }

  @override
  Future<AlbumModel> updateAlbum(AlbumModel album) async {
    // The caller (AlbumNotifier) already resolved the final desired
    // state into [album] itself — a null description/folderId there
    // means "should be cleared", not "leave untouched" (this repo
    // always sends every field, never a partial diff), so derive the
    // explicit clear_* flags the backend requires from that nullness.
    final body = album.toUpdateJson(
      clearDescription: album.description == null,
      clearFolder: album.folderId == null,
    );
    try {
      final json = await _apiClient.patch('/albums/${album.id}', body: body);
      return AlbumModel.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Album "${album.id}" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    try {
      await _apiClient.delete('/albums/$id?mode=${mode.value}');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Album "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<DeletePreviewResponse> previewDeleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    final json = await _apiClient.get('/albums/$id/delete-preview?mode=${mode.value}');
    return DeletePreviewResponse.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TrashedAlbumItem>> fetchDeletedAlbums() async {
    final json = await _apiClient.get('/albums/trash');
    final list = json as List<dynamic>;
    return list.map((e) => TrashedAlbumItem.fromJson(e as Map<String, dynamic>)).toList(growable: false);
  }

  @override
  Future<void> restoreAlbum(String id) async {
    await _apiClient.post('/albums/$id/restore', body: {});
  }
}
