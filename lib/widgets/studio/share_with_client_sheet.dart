import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/auth_providers.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../../providers/studio_shares_provider.dart';
import '../common/empty_state_card.dart';
import '../../core/theme/theme_context.dart';

/// Opens the "Share with client" picker for either a single [albumId]
/// or every album directly inside [folderId] (exactly one of the two
/// must be set) — the studio-side entry point for the curated Shared
/// Gallery feature (Task 17). Only ever lists clients the studio is
/// actually *connected* to (`connectedClientsForStudio`), matching
/// `POST /studio/shares`'s own validation — a client that can't be
/// picked here can never produce a 400 from the backend either.
///
/// Shows a success snackbar itself so every call site (album details,
/// folder details, ...) gets the same feedback for free.
Future<void> showShareWithClientSheet(
  BuildContext context,
  WidgetRef ref, {
  String? albumId,
  String? folderId,
  required String itemLabel,
}) async {
  assert(
    (albumId == null) != (folderId == null),
    'showShareWithClientSheet needs exactly one of albumId/folderId',
  );

  final studioId = ref.read(authStateProvider).user?.id;
  if (studioId == null) return;

  // Connections load lazily via connectionsProvider's own Notifier —
  // just make sure it's initialized so the sheet isn't empty on a cold
  // start.
  final connectedClients = ref
      .read(connectionsProvider.notifier)
      .connectedClientsForStudio(studioId);

  if (!context.mounted) return;

  final selected = await showModalBottomSheet<StudioClientConnection>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _ClientPickerSheet(
      itemLabel: itemLabel,
      connectedClients: connectedClients,
      isLoading: ref.read(connectionsProvider).isLoading,
    ),
  );

  if (selected == null || !context.mounted) return;

  final repo = ref.read(studioSharesRepositoryProvider);
  final clientName = selected.clientData?.name ?? 'this client';

  try {
    if (albumId != null) {
      await repo.shareAlbum(albumId: albumId, clientId: selected.clientId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Shared "$itemLabel" with $clientName')),
      );
    } else {
      final result = await repo.shareFolder(
          folderId: folderId!, clientId: selected.clientId);
      if (!context.mounted) return;
      final message = result.shares.isEmpty
          ? 'This folder has no albums to share yet.'
          : 'Shared ${result.shares.length} album${result.shares.length == 1 ? '' : 's'} '
              'from "$itemLabel" with $clientName';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not share: $e')),
    );
  }
}

class _ClientPickerSheet extends StatelessWidget {
  final String itemLabel;
  final List<StudioClientConnection> connectedClients;
  final bool isLoading;

  const _ClientPickerSheet({
    required this.itemLabel,
    required this.connectedClients,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                'Share "$itemLabel" with…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary,
                ),
              ),
            ),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (connectedClients.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: EmptyStateCard(
                  icon: Icons.people_outline_rounded,
                  message:
                      'No connected clients yet. Connect with a client first '
                      'to share galleries with them.',
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: connectedClients.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final connection = connectedClients[index];
                    final name = connection.clientData?.name ?? 'Client';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.12),
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'C',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      trailing: Icon(Icons.chevron_right_rounded,
                          color: context.textMuted),
                      onTap: () => Navigator.of(context).pop(connection),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
