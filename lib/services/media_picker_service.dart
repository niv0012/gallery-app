import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../models/media_model.dart';
import 'media_upload_service.dart';

/// One picked file, already normalized to what [MediaUploadService.upload]
/// expects — regardless of whether it came from `image_picker` (gallery/
/// camera) or `file_picker` (browse files), and regardless of platform.
///
/// This is the "bytes/XFile → feed into the Task 19.5 service" wiring
/// (Task 19.6): everything downstream (this class, [MediaUploadService],
/// the future `uploadProvider` in Task 19.9) only ever deals with
/// [bytes]/[fileName]/[contentType] — never a raw `XFile`/`PlatformFile`/
/// platform path.
class PickedMediaFile {
  const PickedMediaFile({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final List<int> bytes;
  final String fileName;
  final String contentType;

  int get sizeBytes => bytes.length;

  MediaType get mediaType =>
      contentType.startsWith('video/') ? MediaType.video : MediaType.photo;

  /// Uploads this file via [service], forwarding [albumId]/[folderId]/
  /// [onSendProgress] straight through. This is the literal "feed into
  /// the Task 19.5 service" step — call it directly from a throwaway
  /// test button now, or from `uploadProvider` once Task 19.9 lands.
  Future<MediaModel> uploadWith(
    MediaUploadService service, {
    String? albumId,
    String? folderId,
    void Function(int sentBytes, int totalBytes)? onSendProgress,
  }) {
    return service.upload(
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      albumId: albumId,
      folderId: folderId,
      onSendProgress: onSendProgress,
    );
  }
}

/// What kind of media the user chose to add, mirrors
/// `AddMediaBottomSheet`'s [AddMediaAction] one level down (photos allow
/// picking several at once; a video pick is always single).
enum MediaPickTarget { photos, video }

/// Wraps `image_picker` (gallery/camera — the common "add media" path)
/// and `file_picker` (browse-any-file — used when the user wants to
/// import something outside the photo/video gallery, e.g. a file saved
/// from another app) behind one API that always hands back
/// [PickedMediaFile]s with bytes already read into memory.
///
/// Platform differences are handled here so callers never branch on
/// `kIsWeb` themselves:
/// - `image_picker`'s [XFile.readAsBytes] already works uniformly on
///   both web (blob URL) and mobile (file path) — no branching needed.
/// - `file_picker` differs: on web there is no filesystem, so bytes
///   must be requested eagerly (`withData: true`) and arrive on
///   [PlatformFile.bytes]; on mobile, requesting bytes eagerly for large
///   videos is wasteful, so [PlatformFile.path] is read lazily instead.
///
/// Deliberately NOT a Riverpod provider/notifier — same reasoning as
/// [MediaUploadService]: a plain class the future `uploadProvider`
/// (Task 19.9) can construct and hold, so this stays trivially testable
/// on its own first (e.g. a throwaway button calling [pickPhotos] then
/// [PickedMediaFile.uploadWith]).
class MediaPickerService {
  MediaPickerService({ImagePicker? imagePicker})
      : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  /// Photos from the gallery. Multiple selection, per [AddMediaAction.photos]
  /// in `AddMediaBottomSheet`. Returns an empty list if the user cancels.
  Future<List<PickedMediaFile>> pickPhotos({bool allowMultiple = true}) async {
    if (!allowMultiple) {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery);
      return file == null ? [] : [await _fromXFile(file)];
    }
    final files = await _imagePicker.pickMultiImage();
    return _fromXFiles(files);
  }

  /// A single photo straight from the camera.
  Future<PickedMediaFile?> pickPhotoFromCamera() async {
    final file = await _imagePicker.pickImage(source: ImageSource.camera);
    if (file == null) return null;
    return _fromXFile(file);
  }

  /// A single video, from the gallery or camera, per [AddMediaAction.videos].
  /// `image_picker` only ever returns one video at a time, matching the
  /// bottom sheet's "Choose a video" (singular) subtitle.
  Future<PickedMediaFile?> pickVideo({bool fromCamera = false}) async {
    final file = await _imagePicker.pickVideo(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
    );
    if (file == null) return null;
    return _fromXFile(file);
  }

  /// Convenience matching [MediaPickTarget] directly to
  /// `AddMediaBottomSheet`'s [AddMediaAction] result.
  Future<List<PickedMediaFile>> pickForTarget(MediaPickTarget target) {
    switch (target) {
      case MediaPickTarget.photos:
        return pickPhotos();
      case MediaPickTarget.video:
        return pickVideo().then((f) => f == null ? [] : [f]);
    }
  }

  /// Browse-any-file fallback (not limited to the device's photo/video
  /// gallery) — useful on web/desktop, or when importing a file another
  /// app saved outside the gallery. Restricted to media types by
  /// default; pass [allowedExtensions] to narrow further.
  Future<List<PickedMediaFile>> pickFiles({
    bool allowMultiple = true,
    List<String>? allowedExtensions,
  }) async {
    final type = allowedExtensions == null ? FileType.media : FileType.custom;
    final List<PlatformFile> result;
    if (allowMultiple) {
      result = await FilePicker.pickFiles(
        type: type,
        withData: false,
        allowMultiple: true,
        allowedExtensions: allowedExtensions,
      );
    } else {
      final resultList = await FilePicker.pickFiles(
        type: type,
        withData: false,
        allowMultiple: false,
        allowedExtensions: allowedExtensions,
      );
      final f = resultList.isNotEmpty == true ? resultList.first : null;
      result = f != null ? [f] : [];
    }
    if (result.isEmpty) return [];

    final out = <PickedMediaFile>[];
    for (final f in result) {
      final bytes = await _bytesOfPlatformFile(f);
      if (bytes == null) continue; // e.g. no path and no bytes — skip silently
      out.add(PickedMediaFile(
        bytes: bytes,
        fileName: f.name,
        contentType: MediaContentType.forBytesAndName(bytes, f.name),
      ));
    }
    return out;
  }

  Future<List<int>?> _bytesOfPlatformFile(PlatformFile f) async {
    // file_picker ^12: readAsBytes() works on all platforms.
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<PickedMediaFile> _fromXFile(XFile file) async {
    final bytes = await file.readAsBytes();
    return PickedMediaFile(
      bytes: bytes,
      fileName: file.name,
      // `XFile.mimeType` is reliably populated on web; elsewhere it's
      // often null, so fall back to sniffing bytes then extension.
      contentType: file.mimeType ?? MediaContentType.forBytesAndName(bytes, file.name),
    );
  }

  Future<List<PickedMediaFile>> _fromXFiles(List<XFile> files) async {
    final out = <PickedMediaFile>[];
    for (final f in files) {
      out.add(await _fromXFile(f));
    }
    return out;
  }
}

/// Extension → MIME type sniffing for when neither `image_picker` nor
/// `file_picker` hands back a content type directly. Kept in sync with
/// the video-extension set `UploadQueueController` already uses for its
/// (separate, Hive-based) simulated queue, so a file picked here is
/// classified as photo/video the same way everywhere in the app.
class MediaContentType {
  MediaContentType._();

  static const Map<String, String> _byExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'bmp': 'image/bmp',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'avi': 'video/x-msvideo',
    'm4v': 'video/x-m4v',
    '3gp': 'video/3gpp',
    '3g2': 'video/3gpp2',
    'wmv': 'video/x-ms-wmv',
    'm2ts': 'video/mp2t',
    'mts': 'video/mp2t',
    'ts': 'video/mp2t',
  };

  /// Falls back to `application/octet-stream` for anything unrecognized
  /// — the backend's `POST /media/upload` rejects unsupported content
  /// types itself (see `media_upload_service.dart`), so this only needs
  /// to be a best-effort guess, not a strict validator.
  /// Sniffs the MIME type from the first few bytes of the file, falling back
  /// to filename extension, and then to `application/octet-stream`.
  static String forBytesAndName(List<int> bytes, String fileName) {
    if (bytes.length > 4) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return 'image/jpeg';
      }
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
        return 'image/png';
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
        return 'image/gif';
      }
      if (bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && 
          bytes.length >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
          // ftyp
          final brand = String.fromCharCodes(bytes.sublist(8, 12));
          if (brand == 'heic' || brand == 'heix' || brand == 'hevc' || brand == 'heim') {
            return 'image/heic';
          }
          if (brand == 'mp41' || brand == 'mp42' || brand == 'isom') {
            return 'video/mp4';
          }
      }
    }

    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) {
      return 'application/octet-stream';
    }
    final ext = fileName.substring(dot + 1).toLowerCase();
    return _byExtension[ext] ?? 'application/octet-stream';
  }

  static String forFileName(String fileName) {
    return forBytesAndName([], fileName);
  }
}
