import '../models/media_model.dart';
import 'package:dio/dio.dart';

/// Repository abstraction for offline media management.
///
/// This is designed to mirror the Album/Folder repository style while
/// keeping a clean CRUD API for later Phase UI screens.
class MediaPage {
  final List<MediaModel> data;
  final String? cursor;
  MediaPage({required this.data, this.cursor});
}

abstract class MediaRepository {
  /// All filter params are optional and default to "no filter" so
  /// every existing `fetchMedia()` call site keeps working unchanged.
  /// An API-backed implementation can forward these as query params
  /// (`GET /media?...`) instead of filtering client-side.
  Future<List<MediaModel>> fetchMedia({
    String? albumId,
    String? folderId,
    bool unfiledOnly = false,
    MediaType? type,
    bool favoritesOnly = false,
    String? likedByClientId,
  });

  Future<MediaPage> fetchMediaPage({
    String? albumId,
    String? folderId,
    bool unfiledOnly = false,
    MediaType? type,
    bool favoritesOnly = false,
    String? likedByClientId,
    int? pageSize,
    String? cursor,
  }) async {
    final list = await fetchMedia(
      albumId: albumId,
      folderId: folderId,
      unfiledOnly: unfiledOnly,
      type: type,
      favoritesOnly: favoritesOnly,
      likedByClientId: likedByClientId,
    );
    return MediaPage(data: list);
  }


  Future<MediaModel> createMedia(MediaModel media);

  /// Uploads raw file bytes as a new media item via the multipart
  /// `POST /media/upload` endpoint. [bytes]/[fileName]/[contentType]
  /// come from the picker (Task 19.5/19.6); [onSendProgress] receives
  /// (bytesSent, totalBytes) so callers can show a progress bar. Not
  /// meaningful for [HiveMediaRepository] — see its implementation note.
  Future<MediaModel> uploadMedia({
    List<int>? bytes,
    String? filePath,
    Stream<List<int>> Function()? streamData,
    String? webBlobUrl,
    required String fileName,
    required String contentType,
    int sizeBytes = 0,
    String? albumId,
    String? folderId,
    void Function(int sent, int total)? onSendProgress,
    String? existingUploadId,
    String? existingMediaId,
    Map<String, String>? completedParts,
    void Function(String uploadId, String mediaId)? onUploadStarted,
    void Function(int partNumber, String etag)? onPartUploaded,
    CancelToken? cancelToken,
  });

  Future<MediaModel> updateMedia(MediaModel media);

  Future<void> deleteMedia(String id);

  /// Move media to a different album/folder. Either can be null.
  Future<void> moveMedia({
    required String id,
    String? albumId,
    String? folderId,
  });

  /// Duplicate a media entry into the target album/folder (`null` for
  /// either means "unfiled").
  ///
  /// [HiveMediaRepository] does this metadata-only (new row pointing at
  /// the same local file paths). [ApiMediaRepository] instead calls the
  /// server-side `POST /media/{id}/copy`, which copies the actual file
  /// (+ thumbnail) on disk — cheaper than downloading the bytes to the
  /// client and re-uploading them, especially for large videos.
  Future<MediaModel> copyMedia({
    required String id,
    String? albumId,
    String? folderId,
    DuplicateResolution duplicateResolution = DuplicateResolution.autoRename,
  });

  Future<void> toggleFavorite(String id);

  /// Destructively overwrites this media's original file with newly
  /// edited bytes (photo editor's "Overwrite Original" / "Save as Copy
  /// over original"). [HiveMediaRepository] does this by rewriting the
  /// local file in place; [ApiMediaRepository] calls
  /// `PUT /media/{id}/file`, which backs the current original up
  /// server-side first (once) so [revertMedia] can undo it later.
  Future<MediaModel> replaceMediaFile({
    required String id,
    List<int>? bytes,
    String? filePath,
    required String fileName,
    required String contentType,
  });

  /// Undoes a previous [replaceMediaFile] call by restoring the
  /// pre-edit backup, and clears any non-destructive edit recipe too.
  /// Throws if this media was never overwritten (`MediaModel.canRevert`
  /// is false) — check that before calling, e.g. to enable/disable a
  /// "Revert to Original" button.
  Future<MediaModel> revertMedia(String id);

  Future<List<MediaModel>> fetchDeletedMedia();

  Future<void> permanentlyDeleteMedia(String id);

  Future<void> emptyTrash();

  Future<Map<String, int>> fetchMediaCounts();
}

/// How to handle duplicate [MediaModel.fileName] in the destination when
/// copying/mirroring media.
enum DuplicateResolution {
  /// Preserve current behavior: auto-rename by appending " (i)".
  autoRename,

  /// Do not create a new entry for duplicates.
  skip,
}
