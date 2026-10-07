import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/media_model.dart';
import 'watermark_service.dart';

/// Result of a web-safe in-memory fetch via [MediaFileCache.bytesFor].
///
/// Web has no filesystem to cache into, so instead of a path we hand
/// back the raw bytes plus a filename the caller can pass straight to
/// `XFile.fromData` (share) or `gal` (download).
class MediaBytesResult {
  const MediaBytesResult({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;
}

/// Resolves a [MediaModel] to a real local file path that the
/// device-local [ShareService]/[DownloadService] implementations can
/// work with — both of those only ever understood `File(filePath)`,
/// never a network URL, which is all API-backed media has in
/// [MediaModel.filePath] (left empty on purpose; see
/// [MediaModel.fromApiJson]).
///
/// For device-local media this is just [MediaModel.displayPath]
/// unchanged. For API-backed media ([MediaModel.isDisplayPathNetwork]),
/// the original file is fetched from the backend once into a per-device
/// cache directory and reused on later calls, instead of re-downloading
/// every time the user taps Share/Save.
class MediaFileCache {
  const MediaFileCache();

  static const WatermarkService _watermarker = WatermarkService();

  /// Only photos get the studio logo burned in. Videos are returned
  /// untouched (no video encoder in the app).
  bool _shouldWatermark(MediaModel media, String? watermarkUrl) =>
      watermarkUrl != null &&
      watermarkUrl.isNotEmpty &&
      media.type == MediaType.photo;

  /// Stable, filesystem-safe key for a logo URL (FNV-1a). Used as the
  /// cache sub-folder so a changed logo never reuses old watermarked
  /// files, while the file keeps its normal `<id>.<ext>` name — the name
  /// the client sees in their gallery/share sheet.
  String _logoKey(String url) {
    var h = 0x811c9dc5;
    for (final u in url.codeUnits) {
      h ^= u;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  String _swapExtension(String fileName, String newExt) {
    final dot = fileName.lastIndexOf('.');
    return dot == -1
        ? '$fileName$newExt'
        : '${fileName.substring(0, dot)}$newExt';
  }

  /// Returns a local file path for [media], downloading it first if
  /// it's only available over the network. Returns null if there's
  /// nothing to resolve (no path at all) or the download failed.
  ///
  /// When [watermarkUrl] is given and [media] is a photo, the returned
  /// file has the studio logo burned into its bottom-right corner (so it
  /// survives Download/Share). If the watermark can't be applied this
  /// returns null rather than the clean original.
  Future<String?> localPathFor(
    MediaModel media, {
    String? watermarkUrl,
    Future<String?> Function()? getOriginalUrl,
  }) async {
    final original = await _originalPathFor(media, getOriginalUrl);
    if (original == null || !_shouldWatermark(media, watermarkUrl)) {
      return original;
    }
    return _watermarkedPathFor(media, original, watermarkUrl!);
  }

  Future<String?> _watermarkedPathFor(
    MediaModel media,
    String originalPath,
    String watermarkUrl,
  ) async {
    try {
      final srcExt = _extensionFor(
        media.fileName.isNotEmpty ? media.fileName : originalPath,
        fallback: '.jpg',
      );
      final outExt = WatermarkService.outputExtensionFor(srcExt);
      final dir = Directory(
          '${Directory.systemTemp.path}/gallery_media_cache/wm/${_logoKey(watermarkUrl)}');
      final out = File('${dir.path}/${media.id}$outExt');
      if (await out.exists()) return out.path;

      final bytes = await File(originalPath).readAsBytes();
      final result = await _watermarker.apply(
        imageBytes: bytes,
        extension: srcExt,
        logoUrl: watermarkUrl,
      );
      if (result == null) return null;

      await dir.create(recursive: true);
      await out.writeAsBytes(result.bytes);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _originalPathFor(MediaModel media, Future<String?> Function()? getOriginalUrl) async {
    if (!media.isDisplayPathNetwork) {
      return media.displayPath.isEmpty ? null : media.displayPath;
    }

    final ext = _extensionFor(
      media.fileName,
      fallback: media.type == MediaType.video ? '.mp4' : '.jpg',
    );
    final cacheDir =
        Directory('${Directory.systemTemp.path}/gallery_media_cache');
    final file = File('${cacheDir.path}/${media.id}$ext');

    // Reuse what's already been fetched rather than downloading again
    // on every Share/Save tap for the same item.
    if (await file.exists()) return file.path;

    String url = media.displayPath;
    if (getOriginalUrl != null) {
      final signed = await getOriginalUrl();
      if (signed != null && signed.isNotEmpty) url = signed;
    }

    if (url.isEmpty) return null;

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      await cacheDir.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Web-safe counterpart to [localPathFor]. Web has no `dart:io`
  /// filesystem to cache into, so this fetches [media] straight into
  /// memory and returns the raw bytes instead of a path. Returns null
  /// if there's nothing to resolve or the fetch failed.
  ///
  /// When [watermarkUrl] is given and [media] is a photo, the studio
  /// logo is burned into the returned bytes (see [localPathFor]).
  Future<MediaBytesResult?> bytesFor(
    MediaModel media, {
    String? watermarkUrl,
    Future<String?> Function()? getOriginalUrl,
  }) async {
    final original = await _originalBytesFor(media, getOriginalUrl);
    if (original == null || !_shouldWatermark(media, watermarkUrl)) {
      return original;
    }

    final srcExt = _extensionFor(original.fileName, fallback: '.jpg');
    final result = await _watermarker.apply(
      imageBytes: original.bytes,
      extension: srcExt,
      logoUrl: watermarkUrl!,
    );
    if (result == null) return null;
    return MediaBytesResult(
      bytes: result.bytes,
      fileName: _swapExtension(original.fileName, result.extension),
    );
  }

  Future<MediaBytesResult?> _originalBytesFor(MediaModel media, Future<String?> Function()? getOriginalUrl) async {
    final ext = _extensionFor(
      media.fileName,
      fallback: media.type == MediaType.video ? '.mp4' : '.jpg',
    );
    final fileName =
        media.fileName.isNotEmpty ? media.fileName : '${media.id}$ext';

    if (!media.isDisplayPathNetwork) {
      return null;
    }

    String url = media.displayPath;
    if (getOriginalUrl != null) {
      final signed = await getOriginalUrl();
      if (signed != null && signed.isNotEmpty) url = signed;
    }

    if (url.isEmpty) return null;

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;
      return MediaBytesResult(bytes: response.bodyBytes, fileName: fileName);
    } catch (_) {
      return null;
    }
  }

  String _extensionFor(String fileName, {required String fallback}) {
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return fallback;
    return fileName.substring(dot).toLowerCase();
  }
}
