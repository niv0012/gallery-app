import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder_contents_model.dart';
import '../repositories/folder_repository.dart';
import 'auth_providers.dart';
import 'folder_provider.dart';

enum ExplorerViewMode { gridLarge, gridMedium, gridSmall, list, details }

enum ExplorerSortField { name, date, dateCreated, size }

class FolderExplorerPrefs {
  const FolderExplorerPrefs({
    this.viewMode = ExplorerViewMode.gridMedium,
    this.sortField = ExplorerSortField.name,
    this.ascending = true,
    this.foldersFirst = true,
  });

  final ExplorerViewMode viewMode;
  final ExplorerSortField sortField;
  final bool ascending;
  final bool foldersFirst;

  FolderExplorerPrefs copyWith({
    ExplorerViewMode? viewMode,
    ExplorerSortField? sortField,
    bool? ascending,
    bool? foldersFirst,
  }) {
    return FolderExplorerPrefs(
      viewMode: viewMode ?? this.viewMode,
      sortField: sortField ?? this.sortField,
      ascending: ascending ?? this.ascending,
      foldersFirst: foldersFirst ?? this.foldersFirst,
    );
  }
}

class FolderExplorerPrefsNotifier extends StateNotifier<FolderExplorerPrefs> {
  FolderExplorerPrefsNotifier() : super(const FolderExplorerPrefs()) {
    _load();
  }

  static const _kViewMode = 'folder_explorer_view_mode';
  static const _kSortField = 'folder_explorer_sort_field';
  static const _kAscending = 'folder_explorer_sort_ascending';
  static const _kFoldersFirst = 'folder_explorer_folders_first';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final viewModeIndex = prefs.getInt(_kViewMode);
    final sortFieldIndex = prefs.getInt(_kSortField);
    final ascending = prefs.getBool(_kAscending);
    final foldersFirst = prefs.getBool(_kFoldersFirst);

    state = FolderExplorerPrefs(
      viewMode: (viewModeIndex != null &&
              viewModeIndex >= 0 &&
              viewModeIndex < ExplorerViewMode.values.length)
          ? ExplorerViewMode.values[viewModeIndex]
          : ExplorerViewMode.gridMedium,
      sortField: (sortFieldIndex != null &&
              sortFieldIndex >= 0 &&
              sortFieldIndex < ExplorerSortField.values.length)
          ? ExplorerSortField.values[sortFieldIndex]
          : ExplorerSortField.name,
      ascending: ascending ?? true,
      foldersFirst: foldersFirst ?? true,
    );
  }

  Future<void> setViewMode(ExplorerViewMode mode) async {
    state = state.copyWith(viewMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kViewMode, mode.index);
  }

  Future<void> setSort(ExplorerSortField field, bool ascending) async {
    state = state.copyWith(sortField: field, ascending: ascending);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSortField, field.index);
    await prefs.setBool(_kAscending, ascending);
  }

  Future<void> setFoldersFirst(bool foldersFirst) async {
    state = state.copyWith(foldersFirst: foldersFirst);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFoldersFirst, foldersFirst);
  }
}

final folderExplorerPrefsProvider =
    StateNotifierProvider<FolderExplorerPrefsNotifier, FolderExplorerPrefs>(
  (ref) => FolderExplorerPrefsNotifier(),
);

final folderExplorerEnabledProvider = FutureProvider<bool>((ref) async {
  try {
    final api = ref.read(apiClientProvider);
    final response = await api.get('/config', withAuth: false);
    return response['folder_explorer'] == true;
  } catch (_) {
    return false;
  }
});

final folderContentsProvider =
    FutureProvider.family<FolderContentsRead, String>((ref, folderId) async {
  final user = ref.watch(authProvider).valueOrNull;
  if (user == null) {
    throw Exception('Not authenticated');
  }

  final repo = ref.read(folderRepositoryProvider);
  try {
    return await repo.getContents(folderId);
  } catch (e) {
    rethrow;
  }
});
