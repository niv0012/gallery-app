import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/routes/app_routes.dart';
import '../../providers/face_search_provider.dart';

/// App-bar actions that start a face search from any gallery screen.
///
/// Every screen that shows a folder or an album gets BOTH entry points,
/// so behaviour is identical everywhere:
///   * a scoped icon  — searches only inside that folder (incl. its
///     sub-folders and albums) or that album;
///   * a global icon  — always searches the whole library, even when
///     opened from inside a folder/album.
///
/// Pass neither [folderId] nor [albumId] (e.g. the root of "My Files")
/// to get just the global icon.
List<Widget> faceSearchActions(
  BuildContext context,
  WidgetRef ref, {
  String? folderId,
  String? albumId,
  String? scopeLabel,
}) {
  final scoped = folderId != null || albumId != null;
  final kind = folderId != null ? 'folder' : 'album';

  return [
    if (scoped)
      IconButton(
        tooltip: 'Find by face in this $kind',
        icon: const Icon(Icons.person_search_rounded),
        onPressed: () {
          ref.read(faceSearchProvider.notifier).useMyLibrary(
                folderId: folderId,
                albumId: albumId,
                scopeLabel: scopeLabel,
              );
          Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
        },
      ),
    IconButton(
      tooltip: 'Find by face in entire library',
      icon: const Icon(Icons.face_retouching_natural_rounded),
      onPressed: () {
        ref.read(faceSearchProvider.notifier).useMyLibrary();
        Navigator.of(context).pushNamed(AppRoutes.faceSearchLanding);
      },
    ),
  ];
}
