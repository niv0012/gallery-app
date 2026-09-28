import '../core/network/api_client.dart';
import '../core/utils/app_exceptions.dart';
import '../services/studio_media_upload_service.dart';

/// One settings-backup snapshot for the current studio — mirrors
/// `StudioBackupRead` in `app/schemas/studio.py`. [payload] is the
/// opaque settings JSON as posted (see `settings_local_store.dart` /
/// `AppSettings.toJson()`); the repository doesn't interpret it, only
/// stores/returns it, same as the backend.
class StudioBackupResult {
  final String id;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  const StudioBackupResult({
    required this.id,
    required this.payload,
    required this.createdAt,
  });

  factory StudioBackupResult.fromApiJson(Map<String, dynamic> json) {
    return StudioBackupResult(
      id: json['id'] as String,
      payload: json['payload'] as Map<String, dynamic>,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// A studio managing its OWN profile — logo, cover photo, and Showcase
/// Portfolio grid (Edit Studio Profile screen). Deliberately separate
/// from [StudioDirectoryRepository]/`studioRepositoryProvider`, which is
/// about a *client* browsing/favoriting *other* studios' public
/// profiles — different backend routes (`/studios/me/...` vs
/// `/studios/{id}/...`), different caller, different concerns.
class StudioProfileRepository {
  StudioProfileRepository(
      {required ApiClient apiClient, StudioMediaUploadService? uploadService})
      : _apiClient = apiClient,
        _uploadService =
            uploadService ?? StudioMediaUploadService(apiClient: apiClient);

  final ApiClient _apiClient;
  final StudioMediaUploadService _uploadService;

  /// Uploads/replaces the studio's logo via `POST /studios/me/avatar`.
  /// Returns the new `avatar_url` to display immediately.
  Future<String?> uploadAvatar({
    required List<int> bytes,
    required String fileName,
    required String contentType,
  }) {
    return _uploadService.uploadAvatar(
        bytes: bytes, fileName: fileName, contentType: contentType);
  }

  /// Removes the studio's logo via `DELETE /studios/me/avatar`.
  Future<void> deleteAvatar() async {
    await _apiClient.delete('/studios/me/avatar');
  }

  /// Uploads/replaces the studio's cover photo via `POST /studios/me/cover`.
  /// Returns the new `cover_image_url` to display immediately.
  Future<String?> uploadCover({
    required List<int> bytes,
    required String fileName,
    required String contentType,
  }) {
    return _uploadService.uploadCover(
        bytes: bytes, fileName: fileName, contentType: contentType);
  }

  /// Lists the current studio's Showcase Portfolio images, newest first
  /// (`GET /studios/me/portfolio`).
  Future<List<StudioPortfolioImage>> fetchPortfolio() async {
    final json = await _apiClient.get('/studios/me/portfolio');
    final list = json as List<dynamic>;
    return list
        .map((e) => StudioPortfolioImage.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Adds one image to the Showcase Portfolio grid
  /// (`POST /studios/me/portfolio`).
  Future<StudioPortfolioImage> addPortfolioImage({
    required List<int> bytes,
    required String fileName,
    required String contentType,
  }) {
    return _uploadService.uploadPortfolioImage(
        bytes: bytes, fileName: fileName, contentType: contentType);
  }

  /// Removes one image from the Showcase Portfolio grid
  /// (`DELETE /studios/me/portfolio/{id}`). Throws [NotFoundException]
  /// if it was already removed (e.g. another device deleted it first).
  Future<void> deletePortfolioImage(String imageId) async {
    try {
      await _apiClient.delete('/studios/me/portfolio/$imageId');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw const NotFoundException('This portfolio image no longer exists.');
      }
      rethrow;
    }
  }

  /// Saves a new settings-backup snapshot for the current studio
  /// (`POST /studios/me/backup`). [settingsJson] is sent as-is as the
  /// request body — the backend stores it opaquely (see
  /// `StudioBackup` docstring), so no shape is enforced here either.
  /// Returns the saved record so callers can show its timestamp
  /// immediately without a second request.
  Future<StudioBackupResult> createBackup(
      Map<String, dynamic> settingsJson) async {
    final json =
        await _apiClient.post('/studios/me/backup', body: settingsJson);
    return StudioBackupResult.fromApiJson(json as Map<String, dynamic>);
  }

  /// Returns the current studio's most recent settings backup
  /// (`GET /studios/me/backup`), used both to show "Last backed up:
  /// ..." and, in Task 7, to restore from. Throws [NotFoundException]
  /// if this studio has never made a backup.
  Future<StudioBackupResult> getLatestBackup() async {
    try {
      final json = await _apiClient.get('/studios/me/backup');
      return StudioBackupResult.fromApiJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw const NotFoundException(
            'No backup has been made for this studio yet.');
      }
      rethrow;
    }
  }

  void dispose() => _uploadService.dispose();
}
