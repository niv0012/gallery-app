import '../models/media_model.dart';

sealed class TrashItem {
  String get id;
  String get name;
  DateTime get deletedAt;
}

class TrashedMediaItem extends TrashItem {
  final MediaModel media;
  TrashedMediaItem(this.media);
  
  @override String get id => media.id;
  @override String get name => media.fileName;
  @override DateTime get deletedAt => media.modifiedAt;
}

class TrashedFolderItem extends TrashItem {
  @override final String id;
  @override final String name;
  final DateTime deletedAt;
  final int daysLeft;

  TrashedFolderItem({required this.id, required this.name, required this.deletedAt, required this.daysLeft});
  
  factory TrashedFolderItem.fromJson(Map<String, dynamic> json) => TrashedFolderItem(
    id: json['id'],
    name: json['name'],
    deletedAt: DateTime.parse(json['deleted_at']),
    daysLeft: json['days_left'] as int,
  );
}

class TrashedAlbumItem extends TrashItem {
  @override final String id;
  @override final String name;
  final DateTime deletedAt;
  final int daysLeft;

  TrashedAlbumItem({required this.id, required this.name, required this.deletedAt, required this.daysLeft});
  
  factory TrashedAlbumItem.fromJson(Map<String, dynamic> json) => TrashedAlbumItem(
    id: json['id'],
    name: json['name'],
    deletedAt: DateTime.parse(json['deleted_at']),
    daysLeft: json['days_left'] as int,
  );
}
