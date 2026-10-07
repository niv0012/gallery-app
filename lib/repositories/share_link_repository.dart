import '../core/network/api_client.dart';
import '../models/share_link_model.dart';

/// API-backed repository for `app/api/routes/share_links.py` — both the
/// studio-side CRUD router (`/share-links`, auth required) and the
/// public, token-only guest router (`/public/share-links`, no auth).
///
/// This is the single real implementation; there is no in-memory /
/// local-only variant anymore (see `ShareLinkController`'s doc comment
/// for why the old `ShareLinkLocalStore` had to go — a share link that
/// only exists on the studio's own phone can never be resolved by a
/// guest scanning its QR code or opening its link).
class ShareLinkRepository {
  ShareLinkRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  List<GalleryShareLink> _mapList(dynamic json) {
    final list = json as List<dynamic>;
    return list
        .map((e) => GalleryShareLink.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------
  // Studio-side (auth required)
  // ---------------------------------------------------------------------

  Future<List<GalleryShareLink>> fetchLinks(
      {String? albumId, String? collectionId, String? folderId, bool activeOnly = false}) async {
    final query = <String>[];
    if (albumId != null) query.add('album_id=$albumId');
    if (collectionId != null) query.add('collection_id=$collectionId');
    if (folderId != null) query.add('folder_id=$folderId');
    if (activeOnly) query.add('active_only=true');
    final path = '/share-links${query.isEmpty ? '' : '?${query.join('&')}'}';
    final json = await _apiClient.get(path);
    return _mapList(json);
  }

  Future<GalleryShareLink> createLink({
    String? albumId,
    String? collectionId,
    String? folderId,
    List<String>? albumIds,
    List<String>? folderIds,
    bool includeAll = false,
    bool includeFolderItems = false,
    bool autoIncludeNew = false,
    String kind = 'standard',
    String? clientId,
    String? password,
    DateTime? expiresAt,
    bool allowDownload = true,
    bool showWatermark = false,
  }) async {
    final body = {
      if (albumId != null) 'album_id': albumId,
      if (collectionId != null) 'collection_id': collectionId,
      if (folderId != null) 'source_folder_id': folderId,
      if (albumIds != null) 'album_ids': albumIds,
      if (folderId != null) ...{
        'auto_include_new': autoIncludeNew,
        'include_all': includeAll,
        'include_folder_items': includeFolderItems,
        if (folderIds != null) 'folder_ids': folderIds,
      },
      'kind': kind,
      if (clientId != null && clientId.isNotEmpty) 'client_id': clientId,
      if (password != null && password.isNotEmpty) 'password': password,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
      'allow_download': allowDownload,
      'show_watermark': showWatermark,
    };
    final json = await _apiClient.post('/share-links', body: body);
    return GalleryShareLink.fromApiJson(json as Map<String, dynamic>);
  }

  /// Every field is optional here on purpose (`ShareLinkUpdate` uses
  /// `exclude_unset` server-side) — omitting a field leaves it
  /// untouched, [clearPassword]/[clearExpiry] are the explicit way to
  /// null one out, and a blank/omitted [password] on an already
  /// password-protected link means "keep the existing password", never
  /// "remove it" (the backend has no way to send the plaintext back for
  /// prefilling anyway, since it only ever stores the bcrypt hash).
  Future<GalleryShareLink> updateLink({
    required String id,
    String? clientId,
    bool clearClient = false,
    String? password,
    bool clearPassword = false,
    DateTime? expiresAt,
    bool clearExpiry = false,
    bool? allowDownload,
    bool? showWatermark,
    bool? isRevoked,
    List<String>? albumIds,
    List<String>? folderIds,
    bool? includeAll,
    bool? includeFolderItems,
    bool? autoIncludeNew,
    String? kind,
  }) async {
    final body = {
      if (clientId != null && clientId.isNotEmpty) 'client_id': clientId,
      if (clearClient) 'clear_client': true,
      if (password != null && password.isNotEmpty) 'password': password,
      if (clearPassword) 'clear_password': true,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
      if (clearExpiry) 'clear_expiry': true,
      if (allowDownload != null) 'allow_download': allowDownload,
      if (showWatermark != null) 'show_watermark': showWatermark,
      if (isRevoked != null) 'is_revoked': isRevoked,
      if (albumIds != null) 'album_ids': albumIds,
      if (folderIds != null) 'folder_ids': folderIds,
      if (includeAll != null) 'include_all': includeAll,
      if (includeFolderItems != null) 'include_folder_items': includeFolderItems,
      if (autoIncludeNew != null) 'auto_include_new': autoIncludeNew,
      if (kind != null) 'kind': kind,
    };
    final json = await _apiClient.patch('/share-links/$id', body: body);
    return GalleryShareLink.fromApiJson(json as Map<String, dynamic>);
  }

  Future<void> deleteLink(String id) async {
    await _apiClient.delete('/share-links/$id');
  }

  Future<ShareLinkAnalyticsModel> fetchAnalytics(String id) async {
    final json = await _apiClient.get('/share-links/$id/analytics');
    return ShareLinkAnalyticsModel.fromApiJson(json as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------
  // Public / guest side (optional auth) — used by SharedGalleryScreen
  // ---------------------------------------------------------------------

  Future<ShareLinkStatus> fetchStatus(String token) async {
    // withAuth: true — sends the Bearer token when the user is logged in.
    // The backend's get_optional_current_user handles missing tokens gracefully
    // (returns None), so anonymous guests are unaffected. Logged-in studio
    // owners and assigned clients need this token to pass _assert_client_authorized
    // on links that have a client_id set — without it, they receive a 403.
    final json = await _apiClient.get('/public/share-links/$token/status',
        withAuth: true);
    return ShareLinkStatus.fromApiJson(json as Map<String, dynamic>);
  }

  /// Fetches the shared album + media. Each successful call counts as
  /// one view server-side, so this should only be called once the
  /// passcode gate (if any) has actually been cleared — never
  /// speculatively, or every rebuild would inflate the view counter.
  Future<PublicGalleryData> fetchPublicGallery({
    required String token,
    String? password,
    String? albumId,
  }) async {
    final query = <String>[];
    if (password != null && password.isNotEmpty) {
      query.add('password=${Uri.encodeComponent(password)}');
    }

    final path = albumId != null
        ? '/public/galleries/$token/albums/$albumId'
        : '/public/galleries/$token';

    final url = '$path${query.isEmpty ? '' : '?${query.join('&')}'}';
    final json = await _apiClient.get(url);
    return PublicGalleryData.fromApiJson(json as Map<String, dynamic>);
  }

  /// Fetch the contents of a sub-folder within a folder share link.
  Future<PublicGalleryData> fetchPublicFolder({
    required String token,
    required String folderId,
    String? password,
  }) async {
    final query = <String>[];
    if (password != null && password.isNotEmpty) {
      query.add('password=${Uri.encodeComponent(password)}');
    }
    final url =
        '/public/galleries/$token/folders/$folderId${query.isEmpty ? '' : '?${query.join('&')}'}';
    final json = await _apiClient.get(url);
    return PublicGalleryData.fromApiJson(json as Map<String, dynamic>);
  }

  /// Called right before actually downloading/saving a photo from a
  /// shared gallery — re-validates the password server-side (so a
  /// direct hit on this endpoint can't bypass gallery protection) and,
  /// when [mediaId] is supplied, writes a real Download History row.
  Future<void> recordDownload({
    required String token,
    String? password,
    String? mediaId,
    String? downloaderLabel,
  }) async {
    final body = {
      if (password != null && password.isNotEmpty) 'password': password,
      if (mediaId != null) 'media_id': mediaId,
      if (downloaderLabel != null) 'downloader_label': downloaderLabel,
    };
    await _apiClient.post('/public/share-links/$token/download',
        body: body, withAuth: true);
  }

  Future<String> requestPrivateLink({
    required String token,
    required List<String> mediaIds,
    String? password,
  }) async {
    final body = {
      'media_ids': mediaIds,
    };
    final queryParams = <String, String>{};
    if (password != null && password.isNotEmpty) {
      queryParams['password'] = password;
    }
    
    final queryStr = queryParams.isEmpty 
        ? '' 
        : '?${Uri(queryParameters: queryParams).query}';
        
    final response = await _apiClient.post(
      '/public/share-links/$token/request-private-link$queryStr',
      body: body,
      withAuth: true,
    );
    
    final json = response.data as Map<String, dynamic>;
    return json['token'] as String;
  }

  Future<void> toggleFavourite({
    required String token,
    required String mediaId,
    required String guestIdentifier,
    String? password,
  }) async {
    final body = {
      'media_id': mediaId,
      'guest_identifier': guestIdentifier,
    };
    final queryParams = <String, String>{};
    if (password != null && password.isNotEmpty) {
      queryParams['password'] = password;
    }
    final queryStr = queryParams.isEmpty 
        ? '' 
        : '?${Uri(queryParameters: queryParams).query}';
        
    await _apiClient.post(
      '/public/share-links/$token/favourites$queryStr',
      body: body,
      withAuth: true,
    );
  }
}
