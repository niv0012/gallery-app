import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trash_item.dart';
import '../repositories/media_repository.dart';
import '../repositories/folder_repository.dart';
import '../repositories/album_repository.dart';
import 'admin_dashboard_providers.dart';
import 'media_provider.dart';
import 'folder_provider.dart';
import 'album_provider.dart';

final trashProvider =
    StateNotifierProvider.autoDispose<TrashNotifier, List<TrashItem>>((ref) {
  final mediaRepo = ref.watch(mediaRepositoryProvider);
  final folderRepo = ref.watch(folderRepositoryProvider);
  final albumRepo = ref.watch(albumRepositoryProvider);
  return TrashNotifier(mediaRepo, folderRepo, albumRepo, ref);
});

class TrashNotifier extends StateNotifier<List<TrashItem>> {
  final MediaRepository _mediaRepo;
  final FolderRepository _folderRepo;
  final AlbumRepository _albumRepo;
  final Ref _ref;

  TrashNotifier(this._mediaRepo, this._folderRepo, this._albumRepo, this._ref) : super([]) {
    load();
  }

  Future<void> load() async {
    final deletedMedia = await _mediaRepo.fetchDeletedMedia();
    final deletedFolders = await _folderRepo.fetchDeletedFolders();
    final deletedAlbums = await _albumRepo.fetchDeletedAlbums();

    final items = <TrashItem>[
      ...deletedFolders,
      ...deletedAlbums,
      ...deletedMedia.map((m) => TrashedMediaItem(m)),
    ];

    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    state = items;
  }

  Future<void> restore(String id) async {
    final item = state.firstWhere((m) => m.id == id);
    
    switch (item) {
      case TrashedMediaItem():
        final restored = item.media.copyWith(isDeleted: false, modifiedAt: DateTime.now());
        await _mediaRepo.updateMedia(restored);
        await _ref.read(mediaProvider).load();
        break;
      case TrashedFolderItem():
        await _folderRepo.restoreFolder(item.id);
        _ref.invalidate(folderAsyncProvider);
        break;
      case TrashedAlbumItem():
        await _albumRepo.restoreAlbum(item.id);
        _ref.invalidate(albumAsyncProvider);
        break;
    }

    await load();
    try {
      _ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}
  }

  Future<void> deletePermanently(String id) async {
    final item = state.firstWhere((m) => m.id == id);
    
    if (item is TrashedMediaItem) {
      await _mediaRepo.permanentlyDeleteMedia(id);
      await load();
      try {
        _ref.read(adminDashboardProvider.notifier).refresh();
      } catch (_) {}
    }
  }

  Future<void> emptyTrash() async {
    await _mediaRepo.emptyTrash();
    await load();
    try {
      _ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}
  }
}
