import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'picked_file_info.dart';

final newUploadProvider = StateNotifierProvider.autoDispose<NewUploadNotifier, NewUploadState>((ref) {
  return NewUploadNotifier();
});

class NewUploadState {
  final int wizardStep; // 0 = Selection, 1 = Options
  final List<PickedFileInfo> tempPickedFiles;
  final String? selectedAlbumId;
  final String? selectedFolderId;
  final String? renamePrefix;
  final bool compress;
  final bool wifiOnly;
  final bool keepOriginalQuality;
  final bool uploadMetadata;

  const NewUploadState({
    this.wizardStep = 0,
    this.tempPickedFiles = const [],
    this.selectedAlbumId,
    this.selectedFolderId,
    this.renamePrefix,
    this.compress = false,
    this.wifiOnly = false,
    this.keepOriginalQuality = true,
    this.uploadMetadata = true,
  });

  NewUploadState copyWith({
    int? wizardStep,
    List<PickedFileInfo>? tempPickedFiles,
    String? selectedAlbumId,
    bool clearAlbum = false,
    String? selectedFolderId,
    bool clearFolder = false,
    String? renamePrefix,
    bool clearRenamePrefix = false,
    bool? compress,
    bool? wifiOnly,
    bool? keepOriginalQuality,
    bool? uploadMetadata,
  }) {
    return NewUploadState(
      wizardStep: wizardStep ?? this.wizardStep,
      tempPickedFiles: tempPickedFiles ?? this.tempPickedFiles,
      selectedAlbumId: clearAlbum ? null : (selectedAlbumId ?? this.selectedAlbumId),
      selectedFolderId: clearFolder ? null : (selectedFolderId ?? this.selectedFolderId),
      renamePrefix: clearRenamePrefix ? null : (renamePrefix ?? this.renamePrefix),
      compress: compress ?? this.compress,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      keepOriginalQuality: keepOriginalQuality ?? this.keepOriginalQuality,
      uploadMetadata: uploadMetadata ?? this.uploadMetadata,
    );
  }
}

class NewUploadNotifier extends StateNotifier<NewUploadState> {
  NewUploadNotifier() : super(const NewUploadState());

  void setWizardStep(int step) {
    state = state.copyWith(wizardStep: step);
  }

  void setPickedFiles(List<PickedFileInfo> files) {
    state = state.copyWith(tempPickedFiles: files);
  }

  void addPickedFiles(List<PickedFileInfo> files) {
    state = state.copyWith(
      tempPickedFiles: [...state.tempPickedFiles, ...files],
    );
  }

  void clearPickedFiles() {
    state = state.copyWith(tempPickedFiles: []);
  }

  void updateOptions({
    String? albumId,
    bool clearAlbum = false,
    String? folderId,
    bool clearFolder = false,
    String? renamePrefix,
    bool clearRenamePrefix = false,
    bool? compress,
    bool? wifiOnly,
    bool? keepOriginalQuality,
    bool? uploadMetadata,
  }) {
    state = state.copyWith(
      selectedAlbumId: albumId,
      clearAlbum: clearAlbum,
      selectedFolderId: folderId,
      clearFolder: clearFolder,
      renamePrefix: renamePrefix,
      clearRenamePrefix: clearRenamePrefix,
      compress: compress,
      wifiOnly: wifiOnly,
      keepOriginalQuality: keepOriginalQuality,
      uploadMetadata: uploadMetadata,
    );
  }
}
