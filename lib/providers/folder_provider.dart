import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/app_exceptions.dart';
import '../core/utils/validators.dart';
import '../models/album_model.dart';
import '../models/folder_model.dart';
import '../models/delete_preview_model.dart';
import '../models/stats_models.dart';
import '../repositories/folder_repository.dart';
import 'album_provider.dart';
import 'auth_providers.dart';

enum FolderSortOption {
  name,
  recent,
  albumCount,
}

enum FolderFilterOption {
  all,
  favorites,
  hidden,
}

/// Immutable-ish state model powering the AsyncNotifier provider.
///
/// Note: this intentionally mirrors the public fields/methods exposed by the
/// old `FolderListController` so screens need minimal changes.
@immutable
class FolderState {
  const FolderState({
    required this.isLoading,
    required this.lastError,
    required this.searchQuery,
    required this.sortOption,
    required this.filterOption,
    required this.allFolders,
  });

  final bool isLoading;
  final String? lastError;

  final String searchQuery;
  final FolderSortOption sortOption;
  final FolderFilterOption filterOption;

  final List<FolderModel> allFolders;

  List<FolderModel> get folders => List.unmodifiable(allFolders);

  /// Search + filter + sort applied together — mirrors
  /// `AlbumListController.filteredAlbums` so Folder List can grow a
  /// search/sort bar later without any provider changes.
  List<FolderModel> get filteredFolders {
    Iterable<FolderModel> list = allFolders;

    final q = searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((f) => f.name.toLowerCase().contains(q));
    }

    switch (filterOption) {
      case FolderFilterOption.favorites:
        list = list.where((f) => f.isFavorite);
        break;
      case FolderFilterOption.hidden:
        list = list.where((f) => f.isHidden);
        break;
      case FolderFilterOption.all:
        break;
    }

    final out = list.toList();
    switch (sortOption) {
      case FolderSortOption.name:
        out.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        break;
      case FolderSortOption.recent:
        out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case FolderSortOption.albumCount:
        out.sort((a, b) => b.albumCount.compareTo(a.albumCount));
        break;
    }
    return out;
  }

  FolderStatistics get statistics => FolderStatistics.fromFolders(allFolders);

  FolderState copyWith({
    bool? isLoading,
    String? lastError,
    bool clearLastError = false,
    String? searchQuery,
    FolderSortOption? sortOption,
    FolderFilterOption? filterOption,
    List<FolderModel>? allFolders,
  }) {
    return FolderState(
      isLoading: isLoading ?? this.isLoading,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      searchQuery: searchQuery ?? this.searchQuery,
      sortOption: sortOption ?? this.sortOption,
      filterOption: filterOption ?? this.filterOption,
      allFolders: allFolders ?? this.allFolders,
    );
  }
}

/// AsyncNotifier that hits [FolderRepository.fetchFolders] in build().
class FolderNotifier extends AsyncNotifier<FolderState> {
  FolderRepository get _repo => ref.read(folderRepositoryProvider);

  @override
  Future<FolderState> build() async {
    final userId = ref.watch(authProvider.select((a) => a.valueOrNull?.id));

    // Flush old data completely on account switch to prevent it from bleeding
    // through Riverpod's loading state.
    ref.listen(authProvider.select((a) => a.valueOrNull?.id), (previous, next) {
      if (previous != null && previous != next) {
        ref.invalidateSelf();
      }
    });

    const initial = FolderState(
      isLoading: true,
      lastError: null,
      searchQuery: '',
      sortOption: FolderSortOption.name,
      filterOption: FolderFilterOption.all,
      allFolders: [],
    );

    if (userId == null) {
      return initial.copyWith(isLoading: false);
    }

    // Preserve previous folder data during the async loading phase so
    // screens never flash "Folder not found" or an empty parent picker
    // while a fresh fetch is in progress.
    state = AsyncValue<FolderState>.loading().copyWithPrevious(state);

    try {
      final folders = await _repo.fetchFolders();
      final next = initial.copyWith(isLoading: false, allFolders: folders);

      // Best-effort reconciliation with already-loaded album counts.
      _syncCountsWithAlbumProvider(next);

      return next;
    } catch (e) {
      return initial.copyWith(
        isLoading: false,
        lastError: e.toString(),
        allFolders: state.valueOrNull?.allFolders ?? const [],
      );
    }
  }

  Future<void> load() async {
    // Snapshot current state BEFORE overwriting so we can fall back to it
    // if the fetch fails, and so folderProvider can serve stale-while-
    // revalidate data via copyWithPrevious below.
    final previous = state;
    state = AsyncValue<FolderState>.loading().copyWithPrevious(previous);

    try {
      final folders = await _repo.fetchFolders();
      final current = previous.valueOrNull ?? _empty();
      final next = current.copyWith(isLoading: false, allFolders: folders);

      _syncCountsWithAlbumProvider(next);
      state = AsyncValue.data(next);
    } catch (e) {
      final current = previous.valueOrNull ?? _empty();
      state = AsyncValue.data(
        current.copyWith(isLoading: false, lastError: e.toString()),
      );
    }
  }

  FolderState _empty() {
    return const FolderState(
      isLoading: false,
      lastError: null,
      searchQuery: '',
      sortOption: FolderSortOption.name,
      filterOption: FolderFilterOption.all,
      allFolders: [],
    );
  }

  // ---------------------------------------------------------------------
  // Mutations (compat with old controller API)
  // ---------------------------------------------------------------------

  void setSearchQuery(String value) {
    state = AsyncValue.data(state.value!.copyWith(searchQuery: value));
  }

  void setSortOption(FolderSortOption value) {
    state = AsyncValue.data(state.value!.copyWith(sortOption: value));
  }

  void setFilterOption(FolderFilterOption value) {
    state = AsyncValue.data(state.value!.copyWith(filterOption: value));
  }

  // ---------------------------------------------------------------------
  // Queries (compat)
  // ---------------------------------------------------------------------

  FolderModel? folderById(String id) {
    final current = state.value ?? _empty();
    for (final f in current.allFolders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Direct children (or root folders when [parentId] is null)
  List<FolderModel> childrenOf(String? parentId) {
    final current = state.value ?? _empty();
    return current.allFolders.where((f) => f.parentId == parentId).toList();
  }

  /// Ancestor chain from the root down to (but not including) [folderId].
  List<FolderModel> ancestorsOf(String folderId) {
    final chain = <FolderModel>[];
    final seen = <String>{};
    var current = folderById(folderId);
    if (current == null) return chain;

    while (current!.parentId != null) {
      final parent = folderById(current.parentId!);
      if (parent == null || !seen.add(parent.id)) break;
      chain.insert(0, parent);
      current = parent;
    }
    return chain;
  }

  /// Full breadcrumb — root ... parent, self
  List<FolderModel> breadcrumbFor(String folderId) {
    final self = folderById(folderId);
    if (self == null) return const [];
    return [...ancestorsOf(folderId), self];
  }

  /// All descendants (children, grandchildren, ...) of [folderId],
  /// depth-first.
  List<FolderModel> descendantsOf(String folderId) {
    final result = <FolderModel>[];
    final queue = [folderId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      final children = childrenOf(id);
      for (final c in children) {
        result.add(c);
        queue.add(c.id);
      }
    }
    return result;
  }

  bool _isSelfOrDescendant(String candidateId, String ofId) {
    if (candidateId == ofId) return true;
    return descendantsOf(ofId).any((f) => f.id == candidateId);
  }

  /// Aggregated album count for a folder *and* everything nested under it.
  int aggregateAlbumCount(String folderId) {
    final folder = folderById(folderId);
    if (folder == null) return 0;
    var total = folder.albumCount;
    for (final d in descendantsOf(folderId)) {
      total += d.albumCount;
    }
    return total;
  }

  // ---------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------

  Future<FolderModel> createFolder({
    required String name,
    String? parentId,
  }) async {
    final current = state.value ?? _empty();
    final siblingNames = current.allFolders
        .where((f) => f.parentId == parentId)
        .map((f) => f.name)
        .toList();

    final validName = Validators.ensureValidName(
      name,
      fieldLabel: 'Folder name',
      existingNames: siblingNames,
    );

    final folder = FolderModel(
      id: 'fo-${DateTime.now().microsecondsSinceEpoch}',
      name: validName,
      albumCount: 0,
      parentId: parentId,
      gradientArgb: const [0xFF7C5CFF, 0xFFA855F7, 0xFFEC4899],
    );

    final created = await _repo.createFolder(folder);
    final next = [...current.allFolders, created];

    state = AsyncValue.data(
      current.copyWith(allFolders: next, lastError: null, isLoading: false),
    );

    return created;
  }

  Future<void> renameFolder(String id, String newName) async {
    final current = state.value ?? _empty();
    final folder = folderById(id);
    if (folder == null) {
      throw NotFoundException('Folder "$id" no longer exists');
    }

    final siblingNames = current.allFolders
        .where((f) => f.parentId == folder.parentId && f.id != id)
        .map((f) => f.name)
        .toList();

    final validName = Validators.ensureValidName(
      newName,
      fieldLabel: 'Folder name',
      existingNames: siblingNames,
    );

    await _updateFolder(id, (f) => f.copyWith(name: validName));
  }

  Future<void> moveFolder(String id, String? newParentId) async {
    if (newParentId != null && _isSelfOrDescendant(newParentId, id)) {
      throw const ValidationException(
        "A folder can't be moved into itself or one of its own sub-folders",
      );
    }

    await _updateFolder(
      id,
      (f) => f.copyWith(
        parentId: newParentId,
        clearParent: newParentId == null,
      ),
    );
  }

  Future<void> setHidden(String id, bool isHidden) async {
    await _updateFolder(id, (f) => f.copyWith(isHidden: isHidden));
  }

  /// Updates the folder's own download/watermark rule (null = inherit).
  Future<void> setRules(
    String id, {
    required bool? allowDownload,
    required bool? showWatermark,
  }) async {
    await _updateFolder(
      id,
      (f) => f.copyWith(
        allowDownload: allowDownload,
        showWatermark: showWatermark,
      ),
    );
  }

  Future<void> toggleFavorite(String id) async {
    final folder = folderById(id);
    if (folder == null) return;

    await _updateFolder(id, (f) => f.copyWith(isFavorite: !f.isFavorite));
  }

  /// Deletes a folder according to the requested DeleteMode.
  Future<void> deleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp}) async {
    final folder = folderById(id);
    if (folder == null) {
      throw NotFoundException('Folder "$id" no longer exists');
    }

    await _repo.deleteFolder(id, mode: mode);

    // Refresh everything because the backend handles cascading/reparenting now.
    ref.invalidateSelf();
    await future;
    try {
      ref.invalidate(albumProvider);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Photo/Folder Count Updates — called by albumProvider.
  // ---------------------------------------------------------------------

  void recomputeAlbumCounts(List<AlbumModel> albums) {
    final current = state.value ?? _empty();
    if (current.allFolders.isEmpty) return;

    final counts = <String, int>{};
    for (final a in albums) {
      final folderId = a.folderId;
      if (folderId == null) continue;
      counts[folderId] = (counts[folderId] ?? 0) + 1;
    }

    var changed = false;
    final next = current.allFolders.map((f) {
      final newCount = counts[f.id] ?? 0;
      if (newCount == f.albumCount) return f;
      changed = true;

      final updated = f.copyWith(albumCount: newCount);
      // ignore: unawaited_futures
      _repo.updateFolder(updated);
      return updated;
    }).toList();

    if (!changed) return;

    state = AsyncValue.data(
      current.copyWith(
        allFolders: next,
        lastError: null,
        isLoading: false,
      ),
    );
  }

  void _syncCountsWithAlbumProvider(FolderState folderState) {
    try {
      final albumFacade = ref.read(albumProvider);
      if (albumFacade.allAlbums.isNotEmpty) {
        // Mutates folder counts directly.
        recomputeAlbumCounts(albumFacade.allAlbums);
      } else {
        // Ensure we keep isLoading false even if albums never load.
        state = AsyncValue.data(folderState);
      }
    } catch (_) {
      // Album provider may not be initialized yet.
      state = AsyncValue.data(folderState);
    }
  }

  Future<void> _updateFolder(
    String id,
    FolderModel Function(FolderModel) update,
  ) async {
    final current = state.value ?? _empty();
    final idx = current.allFolders.indexWhere((f) => f.id == id);
    if (idx == -1) throw NotFoundException('Folder "$id" no longer exists');

    final updated = update(current.allFolders[idx]);
    final saved = await _repo.updateFolder(updated);

    final next = [...current.allFolders];
    next[idx] = saved;

    state = AsyncValue.data(
      current.copyWith(
        allFolders: next,
        lastError: null,
        isLoading: false,
      ),
    );
  }
}

final folderRepositoryProvider = Provider<FolderRepository>((ref) {
  // Real backend (`app/api/routes/folders.py`), not the in-memory stub —
  // see [ApiFolderRepository]'s doc comment / [albumRepositoryProvider]
  // for why this matters (persistence across logins, and real UUIDs for
  // things like `POST /media/upload`'s `folder_id`).
  return ApiFolderRepository(apiClient: ref.watch(apiClientProvider));
});

final folderAsyncProvider =
    AsyncNotifierProvider<FolderNotifier, FolderState>(FolderNotifier.new);

class FolderFacade {
  FolderFacade(this._notifier, this._state);

  final FolderNotifier _notifier;
  final FolderState _state;

  // State fields (compat)
  bool get isLoading => _state.isLoading;
  String? get lastError => _state.lastError;
  String get searchQuery => _state.searchQuery;
  FolderSortOption get sortOption => _state.sortOption;
  FolderFilterOption get filterOption => _state.filterOption;

  List<FolderModel> get folders => List.unmodifiable(_state.allFolders);
  List<FolderModel> get filteredFolders => _state.filteredFolders;
  FolderStatistics get statistics => _state.statistics;

  // Actions (compat)
  Future<void> load() => _notifier.load();

  void setSearchQuery(String value) => _notifier.setSearchQuery(value);
  void setSortOption(FolderSortOption value) => _notifier.setSortOption(value);
  void setFilterOption(FolderFilterOption value) =>
      _notifier.setFilterOption(value);

  // -----------------------------------------------------------------------
  // Query methods — implemented directly on _state so they always use the
  // stable snapshotted data and never go through _notifier.state.value
  // (which is null during AsyncValue.loading, causing folders to flash as
  // "not found" and subfolder lists to go empty on every reload).
  // -----------------------------------------------------------------------

  FolderModel? folderById(String id) {
    for (final f in _state.allFolders) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<FolderModel> childrenOf(String? parentId) {
    return _state.allFolders.where((f) => f.parentId == parentId).toList();
  }

  List<FolderModel> ancestorsOf(String folderId) {
    final chain = <FolderModel>[];
    final seen = <String>{};
    var current = folderById(folderId);
    if (current == null) return chain;

    while (current!.parentId != null) {
      final parent = folderById(current.parentId!);
      if (parent == null || !seen.add(parent.id)) break;
      chain.insert(0, parent);
      current = parent;
    }
    return chain;
  }

  List<FolderModel> breadcrumbFor(String folderId) {
    final self = folderById(folderId);
    if (self == null) return const [];
    return [...ancestorsOf(folderId), self];
  }

  List<FolderModel> descendantsOf(String folderId) {
    final result = <FolderModel>[];
    final queue = [folderId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      final children = childrenOf(id);
      for (final c in children) {
        result.add(c);
        queue.add(c.id);
      }
    }
    return result;
  }

  int aggregateAlbumCount(String folderId) {
    final folder = folderById(folderId);
    if (folder == null) return 0;
    var total = folder.albumCount;
    for (final d in descendantsOf(folderId)) {
      total += d.albumCount;
    }
    return total;
  }

  Future<FolderModel> createFolder({
    required String name,
    String? parentId,
  }) =>
      _notifier.createFolder(name: name, parentId: parentId);

  Future<void> renameFolder(String id, String newName) =>
      _notifier.renameFolder(id, newName);
  Future<void> moveFolder(String id, String? newParentId) =>
      _notifier.moveFolder(id, newParentId);
  Future<void> setHidden(String id, bool isHidden) =>
      _notifier.setHidden(id, isHidden);
  Future<void> setRules(
    String id, {
    required bool? allowDownload,
    required bool? showWatermark,
  }) =>
      _notifier.setRules(id, allowDownload: allowDownload, showWatermark: showWatermark);
  Future<void> toggleFavorite(String id) => _notifier.toggleFavorite(id);
  Future<void> deleteFolder(String id, {DeleteMode mode = DeleteMode.moveUp}) =>
      _notifier.deleteFolder(id, mode: mode);

  void recomputeAlbumCounts(List<AlbumModel> albums) =>
      _notifier.recomputeAlbumCounts(albums);
}

/// Provider exported to screens.
///
/// Backwards-compatibility requirement: screens expect `ref.watch(folderProvider)`
/// to expose `folders`, `filteredFolders`, `isLoading`, etc., and they call
/// `ref.read(folderProvider).createFolder(...)`.
final folderProvider = Provider<FolderFacade>((ref) {
  final asyncState = ref.watch(folderAsyncProvider);
  final notifier = ref.read(folderAsyncProvider.notifier);

  // asyncState.valueOrNull now returns the PREVIOUS state during loading
  // because build() / load() both call copyWithPrevious — so screens always
  // get a non-empty folder list while a background refresh runs.
  final value = asyncState.valueOrNull ??
      const FolderState(
        isLoading: true,
        lastError: null,
        searchQuery: '',
        sortOption: FolderSortOption.name,
        filterOption: FolderFilterOption.all,
        allFolders: [],
      );

  return FolderFacade(notifier, value);
});

/// Fetches the effective (ancestor-resolved) allow_download / show_watermark
/// for [folderId] from `GET /folders/{id}/effective-rules`.
///
/// Returned map keys:
///   own_allow_download       bool?  – explicitly set on this folder (null = inherit)
///   own_show_watermark       bool?  – explicitly set on this folder (null = inherit)
///   effective_allow_download bool   – resolved value
///   effective_show_watermark bool   – resolved value
final folderEffectiveRulesProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, folderId) async {
    final repo = ref.watch(folderRepositoryProvider);
    return repo.fetchEffectiveRules(folderId);
  },
);
