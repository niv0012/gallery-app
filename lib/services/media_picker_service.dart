import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

/// MIME type detection for picked media.
///
/// Order of trust: **file header bytes → filename extension →
/// `application/octet-stream`**. The header is checked first because on iOS
/// the picker frequently hands back a file with an empty / extension-less
/// name (the queue then labels it `untitled_N`), so the extension alone can't
/// be relied on.
class MediaContentType {
  MediaContentType._();

  static const String octetStream = 'application/octet-stream';

  static const Map<String, String> _byExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'jpe': 'image/jpeg',
    'jfif': 'image/jpeg',
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
    'dng': 'image/x-adobe-dng',
    'nef': 'image/x-nikon-nef',
    'cr2': 'image/x-canon-cr2',
    'cr3': 'image/x-canon-cr3',
    'orf': 'image/x-olympus-orf',
    'arw': 'image/x-sony-arw',
    'raw': 'image/raw',
  };

  static const Map<String, String> _extensionFor = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'image/heic': 'heic',
    'image/heif': 'heif',
    'image/bmp': 'bmp',
    'video/mp4': 'mp4',
    'video/quicktime': 'mov',
    'video/x-m4v': 'm4v',
    'video/x-matroska': 'mkv',
    'video/webm': 'webm',
    'video/x-msvideo': 'avi',
    'video/3gpp': '3gp',
    'video/3gpp2': '3g2',
    'video/x-ms-wmv': 'wmv',
    'video/mp2t': 'ts',
    'image/x-adobe-dng': 'dng',
    'image/x-nikon-nef': 'nef',
    'image/x-canon-cr2': 'cr2',
    'image/x-canon-cr3': 'cr3',
    'image/x-olympus-orf': 'orf',
    'image/x-sony-arw': 'arw',
    'image/raw': 'raw',
  };

  static String _ascii(List<int> b, int start, int end) =>
      String.fromCharCodes(b.sublist(start, end));

  /// Detects the MIME type from the leading bytes of a file, or `null` when
  /// the signature isn't recognised.
  static String? sniff(List<int> b) {
    if (b.length < 4) return null;

    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'image/png';
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      return 'image/gif';
    }
    // Matroska / WebM (EBML header)
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
      return 'video/x-matroska';
    }

    if (b.length >= 12) {
      final head = _ascii(b, 0, 4);
      final tag = _ascii(b, 8, 12);
      // RIFF containers: WebP / AVI
      if (head == 'RIFF') {
        if (tag == 'WEBP') return 'image/webp';
        if (tag == 'AVI ') return 'video/x-msvideo';
      }
      // ISO base media (`ftyp` box): HEIC/HEIF photos, MP4/MOV/3GP videos
      if (_ascii(b, 4, 8) == 'ftyp') {
        final brand = tag;
        const heic = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis'};
        const heif = {'mif1', 'msf1', 'heif'};
        if (heic.contains(brand)) return 'image/heic';
        if (heif.contains(brand)) return 'image/heif';
        if (brand == 'qt  ') return 'video/quicktime';
        if (brand.startsWith('M4V')) return 'video/x-m4v';
        if (brand.startsWith('3gp')) return 'video/3gpp';
        if (brand.startsWith('3g2')) return 'video/3gpp2';
        if (brand.startsWith('M4A') || brand.startsWith('M4B')) return null;
        if (brand == 'avif' || brand == 'avis') return null;
        // isom, iso2, mp41, mp42, avc1, dash, mmp4, ...
        return 'video/mp4';
      }
    }
    return null;
  }

  static String? _fromExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return _byExtension[fileName.substring(dot + 1).toLowerCase()];
  }

  /// Sniffs [bytes] first, then falls back to the extension of [fileName],
  /// then to `application/octet-stream`.
  static String forBytesAndName(List<int> bytes, String fileName) {
    final sniffed = sniff(bytes);
    final byName = _fromExtension(fileName);
    // Matroska and WebM share a header — trust the extension to tell apart.
    if (sniffed == 'video/x-matroska' && byName == 'video/webm') return byName!;
    return sniffed ?? byName ?? octetStream;
  }

  static String forFileName(String fileName) =>
      _fromExtension(fileName) ?? octetStream;

  /// Native-file variant of [forBytesAndName]: reads only the first bytes of
  /// the file at [path]. Never throws — on any read problem it falls back to
  /// the extension of [fileName] (or of [path]).
  static Future<String> forFile({
    required String? path,
    required String fileName,
  }) async {
    List<int> head = const [];
    if (!kIsWeb && path != null && path.isNotEmpty) {
      try {
        final raf = await File(path).open();
        try {
          head = await raf.read(32);
        } finally {
          await raf.close();
        }
      } catch (_) {
        head = const [];
      }
    }
    var type = forBytesAndName(head, fileName);
    if (type == octetStream && path != null && path.isNotEmpty) {
      type = _fromExtension(path) ?? octetStream;
    }
    return type;
  }

  /// Returns [fileName] guaranteed to carry an extension that matches
  /// [contentType] (`untitled_1` + `image/jpeg` → `untitled_1.jpg`; a
  /// `.heic` name on JPEG data → `.jpg`). Unchanged when [contentType] is
  /// unknown or the name already agrees with it.
  static String withExtension(String fileName, String contentType) {
    final ext = _extensionFor[contentType];
    if (ext == null) return fileName;
    if (_fromExtension(fileName) == contentType) return fileName;
    // `.mkv` vs `.webm` etc. — same family already agreed via forBytesAndName.
    final dot = fileName.lastIndexOf('.');
    final hasExt = dot > 0 && dot < fileName.length - 1 &&
        _byExtension.containsKey(fileName.substring(dot + 1).toLowerCase());
    final base = hasExt ? fileName.substring(0, dot) : fileName;
    return '$base.$ext';
  }
}
