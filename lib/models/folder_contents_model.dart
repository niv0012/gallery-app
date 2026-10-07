import 'album_model.dart';
import 'folder_model.dart';
import 'media_model.dart';

class FolderContentsRead {
  final List<FolderModel> folders;
  final List<AlbumModel> albums;
  final List<MediaModel> media;

  const FolderContentsRead({
    required this.folders,
    required this.albums,
    required this.media,
  });

  factory FolderContentsRead.fromJson(Map<String, dynamic> json) {
    return FolderContentsRead(
      folders: (json['folders'] as List<dynamic>?)
              ?.map((e) => FolderModel.fromApiJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      albums: (json['albums'] as List<dynamic>?)
              ?.map((e) => AlbumModel.fromApiJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      media: (json['media'] as List<dynamic>?)
              ?.map((e) => MediaModel.fromApiJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
