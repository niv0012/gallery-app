import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/app_exceptions.dart';
import '../core/utils/validators.dart';
import '../models/album_model.dart';
import '../models/delete_preview_model.dart';

import '../models/stats_models.dart';
import '../repositories/album_repository.dart';
import 'admin_dashboard_providers.dart';
import 'auth_providers.dart'
    show apiClientProvider, AuthState, authStateProvider, authProvider;
import 'folder_provider.dart';
import 'media_provider.dart';
import 'folder_explorer_provider.dart' show ExplorerViewMode;

enum AlbumSortOption {
  recent,
  name,
  photoCount,
  folderCount,
}

enum AlbumFilterOption {
  all,
  favorites,
}

/// Immutable-ish state model powering the AsyncNotifier provider.
///
/// Note: this intentionally mirrors the public fields/methods exposed by the
/// old `AlbumListController` so screens need minimal changes.
/// Sentinel value used as a `folderId` filter to mean "show only albums
/// that are NOT in any folder" (i.e. unfiled albums). It's a plain
/// String constant — not null — so the nullable `copyWith` machinery
/// doesn't swallow it. The filter dropdown in [AlbumsListScreen] passes
/// this value when the user picks the "Unfiled" option.
const String kUnfiledFolderSentinel = '__unfiled__';

@immutable
class AlbumState {
  const AlbumState({
    required this.isLoading,
    required this.lastError,
    required this.searchQuery,
    required this.sortOption,
    required this.filterOption,
    required this.folderId,
    required this.viewMode,
    required this.allAlbums,
  });

  final bool isLoading;
  final String? lastError;

  final String searchQuery;
  final AlbumSortOption sortOption;
  final AlbumFilterOption filterOption;

  /// Folder used to *filter* the Albums List (distinct from an album's own
  /// [AlbumModel.folderId], which is the real filing link).
  final String? folderId;

  final ExplorerViewMode viewMode;

  final List<AlbumModel> allAlbums;

  List<AlbumModel> get filteredAlbums {
    Iterable<AlbumModel> list = allAlbums;

    final q = searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where(
        (a) =>
            a.name.toLowerCase().contains(q) ||
            (a.description?.toLowerCase().contains(q) ?? false),
      );
    }

    if (filterOption == AlbumFilterOption.favorites) {
      list = list.where((a) => a.isFavorite);
    }

    if (folderId != null) {
      if (folderId == kUnfiledFolderSentinel) {
        // Show only albums that are not filed into any folder.
        list = list.where((a) => a.folderId == null);
      } else {
        // Show only albums in the selected folder.
        list = list.where((a) => a.folderId == folderId);
      }
    }

    final out = list.toList();
    switch (sortOption) {
      case AlbumSortOption.recent:
        out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        break;
      case AlbumSortOption.name:
        out.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        break;
      case AlbumSortOption.photoCount:
        out.sort((a, b) => b.photoCount.compareTo(a.photoCount));
        break;
      case AlbumSortOption.folderCount:
        out.sort((a, b) => b.folderCount.compareTo(a.folderCount));
        break;
    }
    return out;
  }

  List<AlbumModel> get recentAlbums {
    final sorted = [...allAlbums];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted.take(4).toList(growable: false);
  }

  AlbumStatistics statistics({String? folderId}) {
    final scoped = folderId == null
        ? allAlbums
        : allAlbums.where((a) => a.folderId == folderId).toList();
    return AlbumStatistics.fromAlbums(scoped);
  }

  AlbumState copyWith({
    bool? isLoading,
    String? lastError,
    String? searchQuery,
    AlbumSortOption? sortOption,
    AlbumFilterOption? filterOption,
    String? folderId,
    // Set to true to explicitly clear folderId to null ("All folders").
    // Needed because `folderId: null` is ambiguous in nullable copyWith.
    bool clearFolderFilter = false,
    ExplorerViewMode? viewMode,
    List<AlbumModel>? allAlbums,
    bool clearLastError = false,
  }) {
    return AlbumState(
      isLoading: isLoading ?? this.isLoading,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      searchQuery: searchQuery ?? this.searchQuery,
      sortOption: sortOption ?? this.sortOption,
      filterOption: filterOption ?? this.filterOption,
      folderId: clearFolderFilter ? null : (folderId ?? this.folderId),
      viewMode: viewMode ?? this.viewMode,
      allAlbums: allAlbums ?? this.allAlbums,
    );
  }
}

/// Main AsyncNotifier that hits [AlbumRepository.fetchAlbums] in build().
class AlbumNotifier extends AsyncNotifier<AlbumState> {
  AlbumRepository get _repo => ref.read(albumRepositoryProvider);

  @override
  Future<AlbumState> build() async {
    final userId = ref.watch(authProvider.select((a) => a.valueOrNull?.id));

    // When the user switches accounts, flush all old data completely
    // instead of letting Riverpod's AsyncLoading retain the old studio's
    // albums while the new fetch is inflight.
    ref.listen(authProvider.select((a) => a.valueOrNull?.id), (previous, next) {
      if (previous != null && previous != next) {
        ref.invalidateSelf();
      }
    });

    // Keep initial defaults synchronous so screens can build.
    const initial = AlbumState(
      isLoading: true,
      lastError: null,
      searchQuery: '',
      sortOption: AlbumSortOption.recent,
      filterOption: AlbumFilterOption.all,
      folderId: null,
      viewMode: ExplorerViewMode.gridMedium,
      allAlbums: [],
    );

    if (userId == null) {
      return initial.copyWith(isLoading: false);
    }

    state = const AsyncValue.loading();

    try {
      final albums = await _repo.fetchAlbums();
      final next = initial.copyWith(isLoading: false, allAlbums: albums);
      // Best-effort: reconcile folder counts.
      _syncFolderCounts(next.allAlbums);
      return next;
    } catch (e) {
      return initial.copyWith(
          isLoading: false, lastError: e.toString(), allAlbums: const []);
    }
  }

  /// Public method kept for compatibility with old screens.
  Future<void> load() async {
    // Mirrors old behaviour: loading flips immediately.
    state = const AsyncValue.loading();
    try {
      final albums = await _repo.fetchAlbums();
      final current = state.valueOrNull;
      final base = current ?? _empty();
      final next =
          base.copyWith(isLoading: false, lastError: null, allAlbums: albums);
      _syncFolderCounts(next.allAlbums);
      state = AsyncValue.data(next);
    } catch (e) {
      final current = state.valueOrNull ?? _empty();
      state = AsyncValue.data(
          current.copyWith(isLoading: false, lastError: e.toString()));
    }
  }

  /// Like [load] but does NOT transition through [AsyncValue.loading].
  ///
  /// Use this for background refreshes (e.g. triggered after an upload
  /// completes) where the UI should keep showing existing data while the
  /// network request is in-flight, rather than flashing a loading spinner
  /// or rebuilding the whole screen.
  Future<void> refreshSilently() async {
    final current = state.valueOrNull ?? _empty();
    try {
      final albums = await _repo.fetchAlbums();
      final next =
          current.copyWith(isLoading: false, lastError: null, allAlbums: albums);
      _syncFolderCounts(next.allAlbums);
      state = AsyncValue.data(next);
    } catch (_) {
      // Ignore errors during silent refreshes — the UI keeps the
      // stale-but-valid data rather than showing an error banner.
    }
  }

  AlbumState _empty() {
    return const AlbumState(
      isLoading: false,
      lastError: null,
      searchQuery: '',
      sortOption: AlbumSortOption.recent,
      filterOption: AlbumFilterOption.all,
      folderId: null,
      viewMode: ExplorerViewMode.gridMedium,
      allAlbums: [],
    );
  }

  // ---------------------------------------------------------------------
  // UI mutations (compat with old controller API)
  // ---------------------------------------------------------------------

  void setSearchQuery(String value) {
    state = AsyncValue.data(state.value!.copyWith(searchQuery: value));
  }

  void setSortOption(AlbumSortOption value) {
    state = AsyncValue.data(state.value!.copyWith(sortOption: value));
  }

  void setFilterOption(AlbumFilterOption value) {
    state = AsyncValue.data(state.value!.copyWith(filterOption: value));
  }

  void setFolder(String? folderId) {
    if (folderId == null) {
      // Explicitly clear the filter — pass clearFolderFilter so the
      // copyWith null-ambiguity is bypassed and folderId becomes null.
      state = AsyncValue.data(state.value!.copyWith(clearFolderFilter: true));
    } else {
      state = AsyncValue.data(state.value!.copyWith(folderId: folderId));
    }
  }

  void setViewMode(ExplorerViewMode mode) {
    final current = state.value!;
    state = AsyncValue.data(current.copyWith(viewMode: mode));
  }

  // ---------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------

  Future<AlbumModel> createAlbum({
    required String name,
    String? description,
    String? folderId,
  }) async {
    final current = state.value ?? _empty();

    final validName = Validators.ensureValidName(
      name,
      fieldLabel: 'Album name',
      existingNames: current.allAlbums.map((a) => a.name).toList(),
    );
    final validDescription = Validators.ensureValidDescription(description);

    final now = DateTime.now();
    final album = AlbumModel(
      id: 'al-${now.microsecondsSinceEpoch}',
      name: validName,
      description: validDescription,
      createdAt: now,
      updatedAt: now,
      photoCount: 0,
      videoCount: 0,
      folderCount: 0,
      displayOrder: current.allAlbums.length + 1,
      folderId: folderId,
    );

    final created = await _repo.createAlbum(album);

    final nextAlbums = [...current.allAlbums, created];
    final next = current.copyWith(allAlbums: nextAlbums, lastError: null);
    state = AsyncValue.data(next);
    _syncFolderCounts(nextAlbums);
    try {
      ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}
    return created;
  }

  Future<AlbumModel> updateAlbum({
    required String id,
    String? name,
    String? description,
    bool clearDescription = false,
    String? folderId,
    bool clearFolder = false,
  }) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == id);
    if (idx == -1) throw NotFoundException('Album "$id" no longer exists');

    final currentAlbum = current.allAlbums[idx];

    String? validName;
    if (name != null) {
      validName = Validators.ensureValidName(
        name,
        fieldLabel: 'Album name',
        existingNames: current.allAlbums.map((a) => a.name).toList(),
        excludingName: currentAlbum.name,
      );
    }

    String? validDescription;
    var shouldClearDescription = clearDescription;
    if (description != null) {
      validDescription = Validators.ensureValidDescription(description);
      shouldClearDescription =
          shouldClearDescription || validDescription == null;
    }

    final updated = currentAlbum.copyWith(
      name: validName,
      description: validDescription,
      clearDescription: shouldClearDescription,
      folderId: folderId,
      clearFolder: clearFolder,
      updatedAt: DateTime.now(),
    );

    final saved = await _repo.updateAlbum(updated);

    final nextAlbums = [...current.allAlbums];
    nextAlbums[idx] = saved;

    final next = current.copyWith(allAlbums: nextAlbums, lastError: null);
    state = AsyncValue.data(next);

    if (folderId != null || clearFolder) {
      _syncFolderCounts(nextAlbums);
    }

    try {
      ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}

    return saved;
  }

  Future<void> deleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == id);
    if (idx == -1) throw NotFoundException('Album "$id" no longer exists');

    await _repo.deleteAlbum(id, mode: mode);

    ref.invalidateSelf();
    await future;
    _syncMedia();
    try {
      ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}
  }

  void _syncMedia() {
    try {
      ref.read(mediaProvider).load();
    } catch (_) {}
  }

  Future<void> moveToFolder(String albumId, String? folderId) {
    return updateAlbum(
      id: albumId,
      folderId: folderId,
      clearFolder: folderId == null,
    );
  }

  /// Called by [FolderListController.deleteFolder] so albums are unfiled
  /// (never deleted) when their folder goes away.
  void clearFolderAssignment(String folderId) {
    final current = state.value ?? _empty();
    var changed = false;
    final nextAlbums = [...current.allAlbums];

    for (var i = 0; i < nextAlbums.length; i++) {
      if (nextAlbums[i].folderId == folderId) {
        final updated = nextAlbums[i].copyWith(
          clearFolder: true,
          updatedAt: DateTime.now(),
        );
        nextAlbums[i] = updated;
        // ignore: unawaited_futures
        _repo.updateAlbum(updated);
        changed = true;
      }
    }

    if (!changed) return;

    state = AsyncValue.data(current.copyWith(allAlbums: nextAlbums));
    _syncFolderCounts(nextAlbums);
  }

  // ---------------------------------------------------------------------
  // Photo + folder count updates (compat with old controller API)
  // ---------------------------------------------------------------------

  Future<void> setPhotoCount(String albumId, int count) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == albumId);
    if (idx == -1) return;

    final safeCount = count < 0 ? 0 : count;
    final updated = current.allAlbums[idx].copyWith(
      photoCount: safeCount,
      updatedAt: DateTime.now(),
    );

    final saved = await _repo.updateAlbum(updated);
    final nextAlbums = [...current.allAlbums];
    nextAlbums[idx] = saved;

    state = AsyncValue.data(current.copyWith(allAlbums: nextAlbums));
  }

  Future<void> adjustPhotoCount(String albumId, int delta) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == albumId);
    if (idx == -1) return;

    final next = current.allAlbums[idx].photoCount + delta;
    await setPhotoCount(albumId, next);
  }

  Future<void> setFolderCount(String albumId, int count) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == albumId);
    if (idx == -1) return;

    final safeCount = count < 0 ? 0 : count;
    final updated = current.allAlbums[idx].copyWith(
      folderCount: safeCount,
      updatedAt: DateTime.now(),
    );

    final saved = await _repo.updateAlbum(updated);
    final nextAlbums = [...current.allAlbums];
    nextAlbums[idx] = saved;

    state = AsyncValue.data(current.copyWith(allAlbums: nextAlbums));
  }

  Future<void> adjustFolderCount(String albumId, int delta) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == albumId);
    if (idx == -1) return;

    final next = current.allAlbums[idx].folderCount + delta;
    await setFolderCount(albumId, next);
  }

  Future<void> toggleFavorite(String albumId) async {
    final current = state.value ?? _empty();
    final idx = current.allAlbums.indexWhere((a) => a.id == albumId);
    if (idx == -1) return;

    final updated = current.allAlbums[idx].copyWith(
      isFavorite: !current.allAlbums[idx].isFavorite,
    );

    await _replaceAlbumAt(idx, updated);
  }

  Future<void> _replaceAlbumAt(int idx, AlbumModel updated) async {
    final current = state.value ?? _empty();
    final saved =
        await _repo.updateAlbum(updated.copyWith(updatedAt: DateTime.now()));

    final nextAlbums = [...current.allAlbums];
    nextAlbums[idx] = saved;

    state = AsyncValue.data(
        current.copyWith(allAlbums: nextAlbums, lastError: null));
  }

  void _syncFolderCounts(List<AlbumModel> albums) {
    try {
      ref.read(folderProvider).recomputeAlbumCounts(albums);
    } catch (_) {
      // Folder provider not ready yet (e.g. isolated tests) — safe to ignore.
    }
  }
}

final albumRepositoryProvider = Provider<AlbumRepository>((ref) {
  // Real backend (`app/api/routes/albums.py`), not the in-memory stub —
  // see [ApiAlbumRepository]'s doc comment. The in-memory version never
  // persisted anything server-side and handed out client-generated ids
  // that aren't valid UUIDs, which is why picking an album while
  // uploading used to fail (`POST /media/upload`'s `album_id` needs a
  // real UUID) and why albums disappeared on every fresh login/restart.
  return ApiAlbumRepository(apiClient: ref.watch(apiClientProvider));
});

/// Provider exported to screens.
///
/// Backwards-compatibility requirement:
/// - screens expect `ref.watch(albumProvider).allAlbums`, `isLoading`, etc.
/// - screens also call `ref.read(albumProvider).deleteAlbum(...)`.
///
/// Implementation detail:
/// - the underlying AsyncNotifier is `albumAsyncProvider`
/// - `albumProvider` adapts it into a facade-like object compatible with
///   existing code.
final albumAsyncProvider =
    AsyncNotifierProvider<AlbumNotifier, AlbumState>(AlbumNotifier.new);

class AlbumFacade {
  AlbumFacade(this._notifier, this._state);

  final AlbumNotifier _notifier;
  final AlbumState _state;

  // State fields (compat)
  bool get isLoading => _state.isLoading;
  String? get lastError => _state.lastError;
  String get searchQuery => _state.searchQuery;
  AlbumSortOption get sortOption => _state.sortOption;
  AlbumFilterOption get filterOption => _state.filterOption;
  String? get folderId => _state.folderId;
  ExplorerViewMode get viewMode => _state.viewMode;
  List<AlbumModel> get allAlbums => List.unmodifiable(_state.allAlbums);
  List<AlbumModel> get filteredAlbums => _state.filteredAlbums;
  List<AlbumModel> get recentAlbums => _state.recentAlbums;
  AlbumStatistics statistics({String? folderId}) =>
      _state.statistics(folderId: folderId);

  // Actions (compat)
  Future<void> load() => _notifier.load();
  Future<void> refreshSilently() => _notifier.refreshSilently();

  void setSearchQuery(String value) => _notifier.setSearchQuery(value);
  void setSortOption(AlbumSortOption value) => _notifier.setSortOption(value);
  void setFilterOption(AlbumFilterOption value) =>
      _notifier.setFilterOption(value);
  void setFolder(String? folderId) => _notifier.setFolder(folderId);
  void setViewMode(ExplorerViewMode mode) => _notifier.setViewMode(mode);

  Future<void> toggleFavorite(String albumId) =>
      _notifier.toggleFavorite(albumId);

  Future<AlbumModel> createAlbum({
    required String name,
    String? description,
    String? folderId,
  }) =>
      _notifier.createAlbum(
          name: name, description: description, folderId: folderId);

  Future<AlbumModel> updateAlbum({
    required String id,
    String? name,
    String? description,
    bool clearDescription = false,
    String? folderId,
    bool clearFolder = false,
  }) =>
      _notifier.updateAlbum(
        id: id,
        name: name,
        description: description,
        clearDescription: clearDescription,
        folderId: folderId,
        clearFolder: clearFolder,
      );

  Future<void> deleteAlbum(String id, {DeleteMode mode = DeleteMode.moveUp}) =>
      _notifier.deleteAlbum(id, mode: mode);

  Future<void> moveToFolder(String albumId, String? folderId) =>
      _notifier.moveToFolder(albumId, folderId);

  void clearFolderAssignment(String folderId) =>
      _notifier.clearFolderAssignment(folderId);

  Future<void> setPhotoCount(String albumId, int count) =>
      _notifier.setPhotoCount(albumId, count);
  Future<void> adjustPhotoCount(String albumId, int delta) =>
      _notifier.adjustPhotoCount(albumId, delta);
  Future<void> setFolderCount(String albumId, int count) =>
      _notifier.setFolderCount(albumId, count);
  Future<void> adjustFolderCount(String albumId, int delta) =>
      _notifier.adjustFolderCount(albumId, delta);
}

final albumProvider = Provider<AlbumFacade>((ref) {
  final state = ref.watch(albumAsyncProvider);
  final notifier = ref.read(albumAsyncProvider.notifier);

  // Ensure screens always have a concrete facade.
  final value = state.maybeWhen(
    data: (s) => s,
    orElse: () => const AlbumState(
      isLoading: true,
      lastError: null,
      searchQuery: '',
      sortOption: AlbumSortOption.recent,
      filterOption: AlbumFilterOption.all,
      folderId: null,
      viewMode: ExplorerViewMode.gridMedium,
      allAlbums: [],
    ),
  );

  return AlbumFacade(notifier, value);
});

// Ensure existing imports keep a provider with the old name.
// (Screens expect `ref.watch(albumProvider)` / `ref.read(albumProvider)`.)
