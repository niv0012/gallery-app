import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Result of [WatermarkService.apply].
class WatermarkedImage {
  const WatermarkedImage({required this.bytes, required this.extension});

  final Uint8List bytes;

  /// Extension of the encoded [bytes], including the dot (`.jpg`/`.png`).
  final String extension;
}

/// Burns the studio logo into the bottom-right corner of a photo so the
/// watermark is part of the file itself — i.e. it survives Download and
/// Share, not just on-screen viewing.
///
/// Layout matches `WatermarkOverlay` (the on-screen version):
///   logo height = 12% of the shorter side, margin = 3% of the shorter
///   side, logo width <= 30% of the image width, 70% opacity.
///
/// Photos only. Videos can't be watermarked here (no video encoder in
/// the app) — see MediaFileCache, which returns videos untouched.
class WatermarkService {
  const WatermarkService();

  static const double _heightFraction = 0.12;
  static const double _marginFraction = 0.03;
  static const double _maxWidthFraction = 0.30;
  static const double _opacity = 0.7;

  static final Map<String, Uint8List> _logoCache = {};

  /// `.jpg` for JPEG sources; everything else is re-encoded as `.png`
  /// (lossless, keeps transparency, and the `image` package can't
  /// encode WebP).
  static String outputExtensionFor(String extension) {
    final e = extension.toLowerCase();
    return (e == '.jpg' || e == '.jpeg') ? '.jpg' : '.png';
  }

  Future<Uint8List?> _fetchLogo(String url) async {
    final cached = _logoCache[url];
    if (cached != null) return cached;
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      _logoCache[url] = response.bodyBytes;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Returns the watermarked image, or null if the logo couldn't be
  /// fetched or the image couldn't be decoded/encoded. Callers must
  /// treat null as a failure and NOT fall back to the un-watermarked
  /// original, otherwise the watermark could be bypassed.
  Future<WatermarkedImage?> apply({
    required Uint8List imageBytes,
    required String extension,
    required String logoUrl,
  }) async {
    final logo = await _fetchLogo(logoUrl);
    if (logo == null) return null;

    final outExt = outputExtensionFor(extension);
    final out = await compute(
      _burn,
      _BurnArgs(imageBytes, logo, outExt == '.jpg'),
    );
    if (out == null) return null;
    return WatermarkedImage(bytes: out, extension: outExt);
  }
}

class _BurnArgs {
  const _BurnArgs(this.imageBytes, this.logoBytes, this.asJpg);
  final Uint8List imageBytes;
  final Uint8List logoBytes;
  final bool asJpg;
}

/// Runs in a background isolate (decoding a 12–24MP photo on the UI
/// thread would freeze the app).
Uint8List? _burn(_BurnArgs a) {
  try {
    final decoded = img.decodeImage(a.imageBytes, frame: 0);
    final logoDecoded = img.decodeImage(a.logoBytes, frame: 0);
    if (decoded == null || logoDecoded == null) return null;

    // Honour EXIF rotation so the corner is the corner the viewer sees.
    final oriented = img.bakeOrientation(decoded);
    final base = oriented.convert(
      format: img.Format.uint8,
      numChannels: a.asJpg ? 3 : 4,
    );
    final logo = logoDecoded.convert(
      format: img.Format.uint8,
      numChannels: 4,
    );

    final shorter = math.min(base.width, base.height);
    var lh = math.max(16, (shorter * WatermarkService._heightFraction).round());
    var lw = math.max(1, (logo.width * lh / logo.height).round());
    final maxW =
        math.max(1, (base.width * WatermarkService._maxWidthFraction).round());
    if (lw > maxW) {
      lw = maxW;
      lh = math.max(1, (logo.height * lw / logo.width).round());
    }
    lw = math.min(lw, base.width);
    lh = math.min(lh, base.height);

    final resized = img.copyResize(
      logo,
      width: lw,
      height: lh,
      interpolation: img.Interpolation.cubic,
    );
    for (final p in resized) {
      p.a = p.a * WatermarkService._opacity;
    }

    final margin = (shorter * WatermarkService._marginFraction).round();
    img.compositeImage(
      base,
      resized,
      dstX: math.max(0, base.width - lw - margin),
      dstY: math.max(0, base.height - lh - margin),
      dstW: lw,
      dstH: lh,
    );

    return a.asJpg
        ? img.encodeJpg(base, quality: 95)
        : img.encodePng(base, singleFrame: true);
  } catch (_) {
    return null;
  }
}
