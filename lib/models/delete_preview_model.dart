enum DeleteMode {
  moveUp,
  deleteAll,
}

extension DeleteModeExtension on DeleteMode {
  String get value {
    switch (this) {
      case DeleteMode.moveUp:
        return 'move_up';
      case DeleteMode.deleteAll:
        return 'delete_all';
    }
  }
}

class DeletePreviewResponse {
  final DeleteMode mode;
  final int foldersAffected;
  final int albumsAffected;
  final int mediaAffected;

  const DeletePreviewResponse({
    required this.mode,
    required this.foldersAffected,
    required this.albumsAffected,
    required this.mediaAffected,
  });

  factory DeletePreviewResponse.fromJson(Map<String, dynamic> json) {
    final modeStr = json['mode'] as String?;
    final mode = modeStr == 'delete_all' ? DeleteMode.deleteAll : DeleteMode.moveUp;

    return DeletePreviewResponse(
      mode: mode,
      foldersAffected: json['folders_affected'] as int? ?? 0,
      albumsAffected: json['albums_affected'] as int? ?? 0,
      mediaAffected: json['media_affected'] as int? ?? 0,
    );
  }
}
