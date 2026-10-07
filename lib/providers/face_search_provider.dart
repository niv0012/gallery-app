import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../models/face_model.dart';

import '../models/face_search_result_model.dart';
import '../repositories/face_repository.dart';
import '../services/face_recognition_service.dart';
import '../services/permission_service.dart';
import 'auth_providers.dart' show apiClientProvider;

final faceSearchApiServiceProvider = Provider<FaceSearchApiService>((ref) {
  final service = FaceSearchApiService(apiClient: ref.watch(apiClientProvider));
  ref.onDispose(service.dispose);
  return service;
});

final faceRepositoryProvider = Provider<FaceRepository>((ref) {
  return ApiFaceRepository(service: ref.watch(faceSearchApiServiceProvider));
});

/// Which library a face search runs against — mirrors the two backend
/// entry points: the studio's own authenticated library, or one
/// publicly shared album reached via a share-link token.
enum FaceSearchMode { myLibrary, sharedGallery, clientGallery }

class FaceSearchState {
  final FaceSearchMode mode;
  final XFile? selectedSelfie;
  final bool isProcessing;
  final String statusMessage;

  /// Every face the backend found in the selfie itself (not the
  /// gallery) — used to let the person pick a different face via
  /// [FaceSearchNotifier.searchWithFaceIndex] when a selfie has more
  /// than one person in it.
  final List<DetectedFaceModel> detectedFaces;
  final int? searchedFaceIndex;

  final List<FaceSearchResultModel> searchResults;
  final String? error;

  // Scope for FaceSearchMode.myLibrary.
  final String? albumIdFilter;
  final String? folderIdFilter;

  // Scope for FaceSearchMode.sharedGallery.
  final String? shareToken;
  final String? sharePassword;

  /// Human-readable name of the folder/album being searched (shown on
  /// the landing screen). Null means "entire library".
  final String? scopeLabel;

  const FaceSearchState({
    this.mode = FaceSearchMode.myLibrary,
    this.selectedSelfie,
    this.isProcessing = false,
    this.statusMessage = 'Ready',
    this.detectedFaces = const [],
    this.searchedFaceIndex,
    this.searchResults = const [],
    this.error,
    this.albumIdFilter,
    this.folderIdFilter,
    this.shareToken,
    this.sharePassword,
    this.scopeLabel,
  });

  bool get hasMultipleFaces => detectedFaces.length > 1;

  FaceSearchState copyWith({
    FaceSearchMode? mode,
    XFile? selectedSelfie,
    bool? isProcessing,
    String? statusMessage,
    List<DetectedFaceModel>? detectedFaces,
    int? searchedFaceIndex,
    bool clearSearchedFaceIndex = false,
    List<FaceSearchResultModel>? searchResults,
    String? error,
    bool clearError = false,
    String? albumIdFilter,
    String? folderIdFilter,
    String? shareToken,
    String? sharePassword,
    String? scopeLabel,
  }) {
    return FaceSearchState(
      mode: mode ?? this.mode,
      selectedSelfie: selectedSelfie ?? this.selectedSelfie,
      isProcessing: isProcessing ?? this.isProcessing,
      statusMessage: statusMessage ?? this.statusMessage,
      detectedFaces: detectedFaces ?? this.detectedFaces,
      searchedFaceIndex: clearSearchedFaceIndex
          ? null
          : (searchedFaceIndex ?? this.searchedFaceIndex),
      searchResults: searchResults ?? this.searchResults,
      error: clearError ? null : (error ?? this.error),
      albumIdFilter: albumIdFilter ?? this.albumIdFilter,
      folderIdFilter: folderIdFilter ?? this.folderIdFilter,
      shareToken: shareToken ?? this.shareToken,
      sharePassword: sharePassword ?? this.sharePassword,
      scopeLabel: scopeLabel ?? this.scopeLabel,
    );
  }
}

/// Drives the "Find My Photos" flow: pick a selfie, the backend
/// detects + matches faces in one call, results land in
/// [FaceSearchState.searchResults]. There is no separate "index my
/// selfie's face" step anymore — [selectSelfieFile] both detects and
/// searches in a single round trip to the backend.
class FaceSearchNotifier extends Notifier<FaceSearchState> {
  FaceRepository get _repo => ref.read(faceRepositoryProvider);
  final ImagePicker _picker = ImagePicker();

  @override
  FaceSearchState build() => const FaceSearchState();

  /// Scopes subsequent searches to the studio's own library, optionally
  /// filtered to one album/folder. Call this before [pickSelfie] for
  /// the in-app "search my gallery" flow.
  ///
  /// Always starts from a CLEAN state. [FaceSearchState.copyWith] can't
  /// set a field back to null (`null ?? this.x` keeps the old value), so
  /// the old implementation let a previous folder/album scope leak into
  /// the global search — tapping the global icon after a folder search
  /// silently kept searching only that folder.
  void useMyLibrary({String? albumId, String? folderId, String? scopeLabel}) {
    widenedFrom = null;
    state = FaceSearchState(
      mode: FaceSearchMode.myLibrary,
      albumIdFilter: albumId,
      folderIdFilter: folderId,
      scopeLabel: scopeLabel,
    );
  }

  /// Scopes subsequent searches to all active shared albums for the logged-in client.
  void useClientGallery() {
    // Fresh state so a stale studio folder/album scope or share token
    // from an earlier search can never leak into this one.
    state = const FaceSearchState(mode: FaceSearchMode.clientGallery);
  }

  /// Widens a folder/album-scoped search to the studio's whole library
  /// (used by the scope switcher on the landing screen).
  void useEntireLibrary() {
    final s = state;
    final remembered = (s.albumIdFilter != null || s.folderIdFilter != null)
        ? (
            albumId: s.albumIdFilter,
            folderId: s.folderIdFilter,
            label: s.scopeLabel,
          )
        : widenedFrom;
    useMyLibrary();
    // Remember where we came from so the landing screen can flip back.
    widenedFrom = remembered;
  }

  /// The folder/album scope that was widened to "entire library", so the
  /// landing screen's switcher can restore it. Cleared whenever a fresh
  /// search is started from a screen icon.
  ({String? albumId, String? folderId, String? label})? widenedFrom;

  /// Scopes subsequent searches to one publicly shared album. Call this
  /// before [pickSelfie] on the "Shared Gallery" screen a guest reaches
  /// via a share-link token.
  void useSharedGallery({required String token, String? password}) {
    state = FaceSearchState(
      mode: FaceSearchMode.sharedGallery,
      shareToken: token,
      sharePassword: password,
    );
  }

  Future<bool> pickSelfie(ImageSource source) async {
    state = state.copyWith(
        isProcessing: true, statusMessage: 'Opening picker…', clearError: true);

    try {
      if (source == ImageSource.camera) {
        final granted =
            await PermissionService.instance.checkAndRequestCameraPermission();
        if (!granted) {
          state = state.copyWith(
              isProcessing: false, error: 'Camera permission denied.');
          return false;
        }
      }

      final file = await _picker.pickImage(source: source);
      if (file == null) {
        state = state.copyWith(
            isProcessing: false, statusMessage: 'Selection cancelled');
        return false;
      }

      return await selectSelfieFile(file);
    } catch (e) {
      state = state.copyWith(
          isProcessing: false, error: 'Failed to pick image: ${e.toString()}');
      return false;
    }
  }

  /// Uploads [file] to the backend, which detects every face in it and
  /// immediately searches using the largest one. Sets
  /// [FaceSearchState.detectedFaces] so the UI can offer
  /// [searchWithFaceIndex] when more than one face was found.
  Future<bool> selectSelfieFile(XFile file) async {
    state = state.copyWith(
      selectedSelfie: file,
      isProcessing: true,
      statusMessage: 'Detecting and matching faces…',
      clearError: true,
      clearSearchedFaceIndex: true,
    );
    return _runSearch(file, faceIndex: null);
  }

  /// Re-runs the search against the same selfie using a specific
  /// detected face instead of the auto-picked largest one — pass a
  /// `faceIndex` from [FaceSearchState.detectedFaces].
  Future<bool> searchWithFaceIndex(int faceIndex) async {
    final selfie = state.selectedSelfie;
    if (selfie == null) {
      state = state.copyWith(error: 'No selfie selected yet.');
      return false;
    }
    state = state.copyWith(
        isProcessing: true, statusMessage: 'Searching…', clearError: true);
    return _runSearch(selfie, faceIndex: faceIndex);
  }

  Future<bool> _runSearch(XFile selfie, {required int? faceIndex}) async {
    try {
      final FaceSearchApiResponse response;
      if (state.mode == FaceSearchMode.sharedGallery) {
        final token = state.shareToken;
        if (token == null) {
          state = state.copyWith(
              isProcessing: false, error: 'No shared gallery selected.');
          return false;
        }
        response = await _repo.searchSharedGallery(
          token: token,
          selfie: selfie,
          password: state.sharePassword,
          faceIndex: faceIndex,
        );
      } else if (state.mode == FaceSearchMode.clientGallery) {
        response = await _repo.searchClientGallery(
          selfie: selfie,
          faceIndex: faceIndex,
        );
      } else {
        response = await _repo.searchMyLibrary(
          selfie: selfie,
          albumId: state.albumIdFilter,
          folderId: state.folderIdFilter,
          faceIndex: faceIndex,
        );
      }

      state = state.copyWith(
        isProcessing: false,
        statusMessage: response.matches.isEmpty
            ? 'No matches found.'
            : '${response.matches.length} photo(s) matched.',
        detectedFaces: response.detectedFaces,
        searchedFaceIndex: response.searchedFaceIndex,
        searchResults: response.matches,
      );
      return true;
    } on FaceSearchException catch (e) {
      state = state.copyWith(isProcessing: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
          isProcessing: false, error: 'Face search failed: ${e.toString()}');
      return false;
    }
  }

  /// Clears the selfie + results for a "Search again" but KEEPS the
  /// scope (mode, folder/album, share token). The old version wiped the
  /// scope too, so "Search again" after a folder search became a global
  /// search, and after a client-gallery search fell back to the studio
  /// endpoint.
  void reset() {
    final s = state;
    state = FaceSearchState(
      mode: s.mode,
      albumIdFilter: s.albumIdFilter,
      folderIdFilter: s.folderIdFilter,
      shareToken: s.shareToken,
      sharePassword: s.sharePassword,
      scopeLabel: s.scopeLabel,
    );
  }

  /// Drops everything, including the scope.
  void clearAll() {
    state = const FaceSearchState();
  }
}

final faceSearchProvider =
    NotifierProvider<FaceSearchNotifier, FaceSearchState>(
        FaceSearchNotifier.new);
