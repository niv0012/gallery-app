import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/auth_providers.dart';
import '../providers/studio_provider.dart';
import 'media_picker_service.dart' show MediaContentType;

/// Change / remove the logged-in studio's logo (`POST` / `DELETE
/// /studios/me/avatar`) and push the result everywhere it is shown.
///
/// Takes a [ProviderContainer] (not a `WidgetRef`) on purpose: the drawer can
/// be dismissed while an upload is still running, and a container stays valid
/// after the widget that started the action is gone.
class StudioLogoActions {
  StudioLogoActions._();

  /// Lets the user pick an image and uploads it as the new logo.
  /// Returns the new logo URL, or `null` if the picker was cancelled.
  /// Throws if the upload fails (nothing is changed locally in that case).
  static Future<String?> pickAndUpload(ProviderContainer container) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    final contentType =
        picked.mimeType ?? MediaContentType.forFileName(picked.name);
    final url = await container.read(studioProfileRepositoryProvider).uploadAvatar(
          bytes: bytes,
          fileName: picked.name,
          contentType: contentType,
        );
    await _applyLogo(container, url);
    return url;
  }

  /// Removes the logo on the server, then clears it locally.
  /// Throws if the request fails (the logo stays as it was).
  static Future<void> remove(ProviderContainer container) async {
    await container.read(studioProfileRepositoryProvider).deleteAvatar();
    await _applyLogo(container, null);
  }

  /// Updates the signed-in user, the cached studio directory entry and
  /// re-syncs from the backend. [url] `null`/empty means "no logo".
  static Future<void> _applyLogo(
      ProviderContainer container, String? url) async {
    final hasLogo = url != null && url.isNotEmpty;
    final auth = container.read(authProvider.notifier);

    void applyToUser() {
      final current = container.read(authProvider).valueOrNull;
      if (current == null) return;
      auth.setUser(hasLogo
          ? current.copyWith(avatarUrl: url)
          : current.copyWith(clearAvatarUrl: true));
    }

    // Show the change straight away, then confirm against the backend.
    applyToUser();
    container
        .read(studioProvider.notifier)
        .updateCachedBranding(logoUrl: hasLogo ? url : '');

    try {
      await auth.refreshMe();
    } catch (_) {
      // Best effort: the change is already saved server-side.
    }
    applyToUser();

    // Refresh the public directory in the background (clients' Discover
    // screen); it handles its own errors.
    unawaited(container.read(studioProvider.notifier).loadDirectory());
  }
}
