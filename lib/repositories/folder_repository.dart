import '../core/network/api_client.dart';
import '../core/utils/app_exceptions.dart';
import '../models/folder_model.dart';
import '../models/folder_contents_model.dart';
import '../models/delete_preview_model.dart';
import '../models/trash_item.dart';

abstract class FolderRepository {
  Future<List<FolderModel>> fetchFolders();

  /// Persists a brand-new folder and returns the stored copy.
  Future<FolderModel> createFolder(FolderModel folder);

  /// Persists changes to an existing folder (matched by [FolderModel.id])
  /// — covers rename, move (parentId), hidden and favorite toggles, and
  /// album-count refreshes. Throws [NotFoundException] if it no longer
  /// exists.
  Future<FolderModel> updateFolder(FolderModel folder);

  /// Removes a folder. Throws [NotFoundException] if it no longer exists.
  Future<void> deleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp});

  Future<FolderContentsRead> getContents(String id);
  Future<DeletePreviewResponse> previewDeleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp});

  Future<List<TrashedFolderItem>> fetchDeletedFolders();
  Future<void> restoreFolder(String id);

  /// Returns the effective (inherited) allow_download and show_watermark values
  /// for this folder, resolving the nearest explicit ancestor rule.
  /// Keys: own_allow_download, own_show_watermark, effective_allow_download,
  ///        effective_show_watermark. null own values mean purely inherited.
  Future<Map<String, dynamic>> fetchEffectiveRules(String folderId);
}


/// API-backed [FolderRepository], talking to `app/api/routes/folders.py`
/// (`GET/POST/PATCH/DELETE /folders`) via [ApiClient] — see
/// [ApiAlbumRepository]'s doc comment for why this matters: it's what
/// makes folder ids real server UUIDs instead of client-side
/// placeholders that fail UUID validation elsewhere (e.g. uploading
/// media into a folder).
class ApiFolderRepository implements FolderRepository {
  ApiFolderRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  List<FolderModel> _mapList(dynamic json) {
    final list = json as List<dynamic>;
    return list
        .map((e) => FolderModel.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<List<FolderModel>> fetchFolders() async {
    final json = await _apiClient.get('/folders', receiveTimeout: const Duration(seconds: 30));
    return _mapList(json);
  }

  @override
  Future<FolderModel> createFolder(FolderModel folder) async {
    final json = await _apiClient.post('/folders', body: folder.toCreateJson());
    return FolderModel.fromApiJson(json as Map<String, dynamic>);
  }

  @override
  Future<FolderModel> updateFolder(FolderModel folder) async {
    // Same reasoning as ApiAlbumRepository.updateAlbum: [folder] already
    // carries the final desired state, so a null parentId here means
    // "should be cleared", derived into the explicit clear_parent flag
    // the backend requires.
    final body = folder.toUpdateJson(clearParent: folder.parentId == null);
    try {
      final json = await _apiClient.patch('/folders/${folder.id}', body: body);
      return FolderModel.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Folder "${folder.id}" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    try {
      await _apiClient.delete('/folders/$id?mode=${mode.value}');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw NotFoundException('Folder "$id" no longer exists');
      }
      rethrow;
    }
  }

  @override
  Future<FolderContentsRead> getContents(String id) async {
    final json = await _apiClient.get('/folders/$id/contents');
    return FolderContentsRead.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<DeletePreviewResponse> previewDeleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    final json = await _apiClient.get('/folders/$id/delete-preview?mode=${mode.value}');
    return DeletePreviewResponse.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TrashedFolderItem>> fetchDeletedFolders() async {
    final json = await _apiClient.get('/folders/trash');
    final list = json as List<dynamic>;
    return list.map((e) => TrashedFolderItem.fromJson(e as Map<String, dynamic>)).toList(growable: false);
  }

  @override
  Future<void> restoreFolder(String id) async {
    await _apiClient.post('/folders/$id/restore', body: {});
  }

  @override
  Future<Map<String, dynamic>> fetchEffectiveRules(String folderId) async {
    final json = await _apiClient.get('/folders/$folderId/effective-rules');
    return Map<String, dynamic>.from(json as Map);
  }
}
