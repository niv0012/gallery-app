import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../albums/albums_list_screen.dart';
import '../folders/folder_explorer_screen.dart';
import '../../providers/folder_explorer_provider.dart';

/// Studio Gallery tab body — Admin-only Albums & Folder Management entry
/// point. Lives inside [AdminMainNavScreen], replacing the old
/// "coming soon" placeholder now that Albums List is available.
///
/// This tab is exclusive to the Admin dashboard; the Client dashboard's
/// Gallery tab (see lib/screens/client/gallery_screen.dart) intentionally
/// stays a view-only placeholder and is untouched by this change.
class AdminGalleryScreen extends ConsumerWidget {
  const AdminGalleryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledAsync = ref.watch(folderExplorerEnabledProvider);
    return enabledAsync.maybeWhen(
      data: (enabled) =>
          enabled ? const FolderExplorerScreen() : const AlbumsListScreen(),
      orElse: () => const AlbumsListScreen(),
    );
  }
}
