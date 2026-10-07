import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../models/share_link_model.dart';
import '../repositories/share_link_repository.dart';
import 'auth_providers.dart';

final shareLinkRepositoryProvider = Provider<ShareLinkRepository>((ref) {
  return ShareLinkRepository(apiClient: ref.watch(apiClientProvider));
});

/// Studio-side controller for a single album's share link — replaces
/// the old local-only `ShareLinkNotifier`, which stored links purely on
/// the device (`ShareLinkLocalStore`) and never touched the backend, so
/// a link/QR generated on the studio's phone only ever existed on that
/// phone. This talks to the real `/share-links` API instead, so any
/// link it creates is a real row a guest's phone can actually resolve.
///
/// Scoped per-album (via `.family`) rather than loading every link for
/// every album up front — `ShareSettingsScreen` only ever needs the one
/// album it's showing.
class ShareTarget {
  final String? albumId;
  final String? collectionId;
  final String? folderId;

  const ShareTarget({this.albumId, this.collectionId, this.folderId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShareTarget &&
          runtimeType == other.runtimeType &&
          albumId == other.albumId &&
          collectionId == other.collectionId &&
          folderId == other.folderId;

  @override
  int get hashCode => Object.hash(albumId, collectionId, folderId);
}

class ShareLinkController extends ChangeNotifier {
  ShareLinkController(
      {required ShareLinkRepository repository, required this.target})
      : _repo = repository;

  final ShareLinkRepository _repo;
  final ShareTarget target;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  List<GalleryShareLink> _activeLinks = [];
  List<GalleryShareLink> get activeLinks => _activeLinks;

  // Backwards compatibility for screens that only expect one link
  GalleryShareLink? get activeLink => _activeLinks.isEmpty ? null : _activeLinks.first;

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final links = await _repo.fetchLinks(
        albumId: target.albumId,
        collectionId: target.collectionId,
        folderId: target.folderId,
      );
      _activeLinks = links.where((l) => !l.isRevoked).toList();
    } catch (e) {
      _error = e is ApiException ? e.message : e.toString();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<GalleryShareLink> createLink({
    String? clientId,
    String? password,
    DateTime? expiresAt,
    required bool allowDownload,
    required bool showWatermark,
    List<String>? albumIds,
    List<String>? folderIds,
    bool includeAll = false,
    bool includeFolderItems = false,
    bool autoIncludeNew = false,
    String? kind,
  }) async {
    final result = await _repo.createLink(
      albumId: target.albumId,
      collectionId: target.collectionId,
      folderId: target.folderId,
      albumIds: albumIds,
      folderIds: folderIds,
      includeAll: includeAll,
      includeFolderItems: includeFolderItems,
      autoIncludeNew: autoIncludeNew,
      kind: kind ?? 'standard',
      clientId: clientId,
      password: password,
      expiresAt: expiresAt,
      allowDownload: allowDownload,
      showWatermark: showWatermark,
    );
    _activeLinks.add(result);
    notifyListeners();
    return result;
  }

  Future<GalleryShareLink> updateLink({
    required String id,
    String? clientId,
    bool clearClient = false,
    String? password,
    bool clearPassword = false,
    DateTime? expiresAt,
    bool clearExpiry = false,
    required bool allowDownload,
    required bool showWatermark,
    List<String>? albumIds,
    List<String>? folderIds,
    bool? includeAll,
    bool? includeFolderItems,
    bool autoIncludeNew = false,
    String? kind,
  }) async {
    final result = await _repo.updateLink(
      id: id,
      clientId: clientId,
      clearClient: clearClient,
      password: password,
      clearPassword: clearPassword,
      expiresAt: expiresAt,
      clearExpiry: clearExpiry,
      allowDownload: allowDownload,
      showWatermark: showWatermark,
      albumIds: albumIds,
      folderIds: folderIds,
      includeAll: includeAll,
      includeFolderItems: includeFolderItems,
      autoIncludeNew: autoIncludeNew,
      kind: kind,
    );
    final index = _activeLinks.indexWhere((l) => l.id == id);
    if (index != -1) {
      _activeLinks[index] = result;
    }
    notifyListeners();
    return result;
  }

  Future<void> revoke(String id) async {
    await _repo.updateLink(id: id, isRevoked: true);
    _activeLinks.removeWhere((l) => l.id == id);
    notifyListeners();
  }
}

final shareLinkControllerProvider =
    ChangeNotifierProvider.family<ShareLinkController, ShareTarget>((ref, target) {
  final controller = ShareLinkController(
    repository: ref.watch(shareLinkRepositoryProvider),
    target: target,
  );
  Future.microtask(controller.load);
  return controller;
});

/// What [PublicGalleryController] is currently showing — distinct
/// statuses so `SharedGalleryScreen` can render the right message
/// instead of a generic "something went wrong" for every failure mode.
enum PublicGalleryStatus {
  loading,
  needsPassword,
  wrongPassword,
  notFound,
  albumDeleted,
  revoked,
  expired,
  unauthorized,
  downloadsDisabled,
  error,
  loaded,
}

/// Guest-side controller for viewing a shared gallery by [token] — the
/// real counterpart to [ShareLinkController]. Scoped per-token so
/// `SharedGalleryScreen` (reached via a `picgallery://shared/{token}`
/// deep link or "Preview Client View") gets a fresh instance per link.
class PublicGalleryController extends ChangeNotifier {
  PublicGalleryController(
      {required ShareLinkRepository repository, required this.token, this.albumId})
      : _repo = repository;

  final ShareLinkRepository _repo;
  final String token;
  final String? albumId;

  PublicGalleryStatus _status = PublicGalleryStatus.loading;
  PublicGalleryStatus get status => _status;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  PublicGalleryData? _data;
  PublicGalleryData? get data => _data;

  /// The password that successfully unlocked this gallery, remembered
  /// so [recordDownload] can re-send it. `/public/share-links/{token}`
  /// isn't session-based — every request re-validates the password
  /// server-side (`_assert_password_ok`), including the download-record
  /// endpoint. Previously nothing kept this around after [unlock], so
  /// every download from a password-protected gallery silently failed
  /// its 401 in [recordDownload]'s catch-all: `downloads_count` never
  /// incremented and no Download History row was ever written for any
  /// private gallery, even though the actual file save (which doesn't
  /// go through this endpoint) worked fine — a studio just never saw
  /// who downloaded what from their password-protected shares.
  String? _password;

  /// Exposes [_password] so callers that need to re-authenticate against
  /// this same gallery from elsewhere (e.g. kicking off a face search via
  /// `/public/share-links/{token}/face-search`, which is password-gated
  /// exactly like every other endpoint on a private link) don't have to
  /// re-prompt for a password the guest already entered once this session.
  String? get password => _password;

  /// Runs once on creation: checks whether the link needs a passcode
  /// before ever fetching (and counting a view for) the full gallery.
  Future<void> checkStatus() async {
    debugPrint(
        '[API_LOOKUP_DEBUG] PublicGalleryController checking status for token/shareId: $token');
    _status = PublicGalleryStatus.loading;
    notifyListeners();

    try {
      final status = await _repo.fetchStatus(token);
      debugPrint(
          '[API_LOOKUP_DEBUG] Status response - requiresPassword: ${status.requiresPassword}, isActive: ${status.isActive}');
      if (!status.isActive) {
        // The status endpoint doesn't distinguish revoked vs. expired
        // (both just collapse to `is_active: false`) — fetching once
        // more against the main endpoint gets the specific 410 reason
        // instead of guessing.
        await unlock();
        return;
      }
      if (status.requiresPassword) {
        _status = PublicGalleryStatus.needsPassword;
        notifyListeners();
      } else {
        await unlock();
      }
    } catch (e) {
      _handleError(e);
    }
  }

  Future<void> unlock({String? password}) async {
    debugPrint(
        '[API_LOOKUP_DEBUG] PublicGalleryController unlocking token: $token (hasPassword: ${password != null})');
    _status = PublicGalleryStatus.loading;
    notifyListeners();

    try {
      _data = await _repo.fetchPublicGallery(token: token, password: password, albumId: albumId);
      _status = PublicGalleryStatus.loaded;
      _password = password;
      // Reset folder navigation on fresh unlock
      _folderStack.clear();
      debugPrint(
          '[API_LOOKUP_DEBUG] PublicGalleryController successfully loaded gallery: ${_data?.album?.name ?? _data?.collection?.name}');
    } catch (e) {
      _handleError(e,
          isPasswordAttempt: password != null && password.isNotEmpty);
    }
    notifyListeners();
  }

  // --- Folder navigation stack ---
  /// Stack of (folderId, folderName) pairs representing the current breadcrumb.
  final List<(String id, String name)> _folderStack = [];
  List<(String id, String name)> get folderStack => List.unmodifiable(_folderStack);

  /// Whether we're currently browsing inside a sub-folder.
  bool get isInsideSubFolder => _folderStack.isNotEmpty;

  /// Navigate into a sub-folder, loading its contents from the backend.
  Future<void> navigateToFolder(String folderId, String folderName) async {
    _status = PublicGalleryStatus.loading;
    notifyListeners();
    try {
      final result = await _repo.fetchPublicFolder(
        token: token,
        folderId: folderId,
        password: _password,
      );
      _data = result;
      _folderStack.add((folderId, folderName));
      _status = PublicGalleryStatus.loaded;
    } catch (e) {
      _handleError(e);
    }
    notifyListeners();
  }

  /// Navigate back up one level in the folder hierarchy.
  Future<void> navigateBack() async {
    if (_folderStack.isEmpty) return;
    _folderStack.removeLast();
    _status = PublicGalleryStatus.loading;
    notifyListeners();
    try {
      if (_folderStack.isEmpty) {
        // Back to root
        _data = await _repo.fetchPublicGallery(token: token, password: _password);
      } else {
        final (parentId, _) = _folderStack.last;
        _data = await _repo.fetchPublicFolder(
          token: token,
          folderId: parentId,
          password: _password,
        );
        // We already popped, so re-add last entry after fetch
      }
      _status = PublicGalleryStatus.loaded;
    } catch (e) {
      _handleError(e);
    }
    notifyListeners();
  }

  Future<String> requestPrivateLink(List<String> mediaIds) async {
    return await _repo.requestPrivateLink(
      token: token,
      password: _password,
      mediaIds: mediaIds,
    );
  }

  void _handleError(Object error, {bool isPasswordAttempt = false}) {
    debugPrint(
        '[API_LOOKUP_DEBUG] PublicGalleryController error for token $token: $error');
    if (error is ApiException) {
      switch (error.statusCode) {
        case 404:
          if (error.message.toLowerCase().contains('no longer available') ||
              error.message.toLowerCase().contains('album')) {
            _status = PublicGalleryStatus.albumDeleted;
          } else {
            _status = PublicGalleryStatus.notFound;
          }
          break;
        case 403:
          _status = PublicGalleryStatus.unauthorized;
          break;
        case 401:
          _status = isPasswordAttempt
              ? PublicGalleryStatus.wrongPassword
              : PublicGalleryStatus.needsPassword;
          break;
        case 410:
          _status = error.message.toLowerCase().contains('revoked')
              ? PublicGalleryStatus.revoked
              : PublicGalleryStatus.expired;
          break;
        default:
          _status = PublicGalleryStatus.error;
          _errorMessage = error.message;
      }
    } else {
      _status = PublicGalleryStatus.error;
      _errorMessage =
          "Couldn't reach the server. Check your connection and try again.";
    }
  }

  /// Fire-and-forget, same as the old local `incrementDownloads` this
  /// replaces — a failed analytics/history write shouldn't block the
  /// download itself, which has already happened by the time this is
  /// called from the viewer/player screens.
  ///
  /// Defaults [password] to whatever unlocked this gallery ([_password])
  /// — callers (`ImageViewerScreen`/`VideoPlayerScreen`) never had the
  /// password to pass in the first place, so without this default every
  /// call against a private gallery re-validated with `password: null`
  /// and 401'd every time. An explicit [password] argument still wins,
  /// for any future caller that has a fresher one than what's cached.
  Future<void> recordDownload({String? password, String? mediaId}) async {
    try {
      await _repo.recordDownload(
        token: token,
        password: password ?? _password,
        mediaId: mediaId,
      );
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> toggleFavourite(String mediaId, String guestIdentifier) async {
    try {
      await _repo.toggleFavourite(
        token: token,
        mediaId: mediaId,
        guestIdentifier: guestIdentifier,
        password: _password,
      );
    } catch (e) {
      debugPrint('[API_LOOKUP_DEBUG] Error toggling favourite: $e');
      rethrow;
    }
  }
}

class PublicGalleryTarget {
  final String token;
  final String? albumId;

  const PublicGalleryTarget({required this.token, this.albumId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PublicGalleryTarget &&
          runtimeType == other.runtimeType &&
          token == other.token &&
          albumId == other.albumId;

  @override
  int get hashCode => Object.hash(token, albumId);
}

final publicGalleryControllerProvider = ChangeNotifierProvider.family<
    PublicGalleryController, PublicGalleryTarget>((ref, target) {
  final controller = PublicGalleryController(
    repository: ref.watch(shareLinkRepositoryProvider),
    token: target.token,
    albumId: target.albumId,
  );
  Future.microtask(controller.checkStatus);
  return controller;
});
