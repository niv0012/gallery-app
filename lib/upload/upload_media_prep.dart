import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import '../services/image_compression_service.dart';

/// Provides [ImageCompressionService]. Overridable in tests.
final imageCompressionServiceProvider =
    Provider<ImageCompressionService>((_) => const ImageCompressionService());

/// Single source of truth for "should this file be compressed before
/// upload, and if so, what are the resulting bytes". Every upload entry
/// point (the batch queue in upload_queue_provider.dart and the
/// single-file uploader in upload_provider.dart) calls this instead of
/// each reimplementing the Upload Resolution check.
///
/// Reads `settings.uploadQuality` (the global "Original" / "High" toggle
/// on the Settings screen — see settings_model.dart /
/// admin_settings_screen.dart):
/// - `"Original"`: [bytes] are returned unchanged.
/// - `"High"`: for photos, [bytes] are downscaled/re-encoded via
///   [ImageCompressionService] (long edge ~2048px, JPEG quality ~85).
///   For videos, compression isn't wired up yet — see TODO below — so
///   [bytes] are returned unchanged for now rather than silently
///   dropping quality settings on a format we can't safely re-encode
///   client-side.
///
/// [forceCompress], when non-null, overrides the global setting above
/// for this one call — this is how the upload wizard's per-batch
/// "Compress Media" / "Keep Original Quality" toggles (job.compress /
/// job.keepOriginalQuality on UploadJobModel) take effect: the batch
/// queue derives a bool from those two switches and passes it here so
/// an explicit per-batch choice wins over whatever the global default
/// happens to be for that job. Leave it null (as the single-file
/// uploader does) to fall through to the global setting untouched.
Future<List<int>> prepareMediaBytesForUpload(
  Ref ref, {
  required List<int> bytes,
  required String contentType,
  bool? forceCompress,
}) async {
  final settings = ref.read(settingsProvider);
  final shouldCompress = forceCompress ?? (settings.uploadQuality == 'High');
  if (!shouldCompress) {
    return bytes;
  }

  if (contentType.startsWith('image/')) {
    if (contentType == 'image/raw' || contentType.startsWith('image/x-')) {
      return bytes; // Skip RAW formats (cannot be compressed by pure-Dart image package)
    }
    return ref.read(imageCompressionServiceProvider).compress(bytes);
  }

  if (contentType.startsWith('video/')) {
    // TODO(upload-quality): "High" for video should re-encode to a
    // lower-bitrate preset once the app has a video transcoding path
    // (client-side re-encoding needs a native/ffmpeg-backed plugin,
    // unlike the pure-Dart image compression used for photos above).
    // Uploading as-is for now rather than silently corrupting/blocking
    // video uploads.
    return bytes;
  }

  return bytes;
}
