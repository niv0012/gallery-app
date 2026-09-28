import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';

/// Client-side Invitation Management Screen.
///
/// Displays all pending Studio invitations (pendingStudioRequest status)
/// and allows the Client to Accept or Decline them via the real backend
/// (`POST /connections/{id}/accept` / `.../decline`).
///
/// [connectionsProvider] is already scoped to the current user —
/// `GET /connections` only ever returns rows belonging to whoever's
/// token made the request — so every row in [connections] here already
/// belongs to this client; no extra id filter is needed.
class InvitationsScreen extends ConsumerWidget {
  const InvitationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider).valueOrNull ?? [];
    final connNotifier = ref.read(connectionsProvider.notifier);

    // Get pending studio invitations for this client
    final pendingInvites = connections
        .where((c) => c.status == ConnectionStatus.pendingStudioRequest)
        .toList();

    // Get previously rejected invitations (for history)
    final rejectedInvites = connections
        .where((c) =>
            c.status == ConnectionStatus.rejected && c.initiatedBy == 'studio')
        .toList();

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Studio Invitations',
        showBack: true,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: connNotifier.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(AppSpacing.md),
            children: [
              // Pending invitations section
              _SectionHeader(
                title: 'Pending Invitations',
                count: pendingInvites.length,
                icon: Icons.mail_outline_rounded,
              ),
              SizedBox(height: AppSpacing.sm),
              if (pendingInvites.isEmpty)
                const _EmptyState(
                  icon: Icons.mail_outline_rounded,
                  message: 'No pending studio invitations',
                  subtitle:
                      'When a Studio sends you an invitation,\nit will appear here.',
                )
              else
                ...pendingInvites.map((invite) => _InvitationCard(
                      invitation: invite,
                      key: ValueKey(invite.id),
                      onAccept: () async {
                        try {
                          await connNotifier.clientAcceptInvite(invite.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Accepted invitation from ${invite.clientData?.name ?? "Studio"}'),
                                backgroundColor: AppColors.success,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Could not accept invitation. Try again.'),
                                backgroundColor: AppColors.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      },
                      onReject: () async {
                        try {
                          await connNotifier.clientDeclineInvite(invite.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Invitation declined'),
                                backgroundColor: AppColors.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Could not decline invitation. Try again.'),
                                backgroundColor: AppColors.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      },
                    )),

              // Divider if there are rejected invites
              if (rejectedInvites.isNotEmpty) ...[
                SizedBox(height: AppSpacing.xl),
                _SectionHeader(
                  title: 'Declined Invitations',
                  count: rejectedInvites.length,
                  icon: Icons.history_rounded,
                ),
                SizedBox(height: AppSpacing.sm),
                ...rejectedInvites.map((invite) => _RejectedInviteCard(
                      key: ValueKey(invite.id),
                      invitation: invite,
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final IconData icon;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(width: 8),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.message,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: context.surfaceColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon,
              color: context.textMuted.withValues(alpha: 0.4), size: 48),
          SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _InvitationCard extends StatelessWidget {
  final StudioClientConnection invitation;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _InvitationCard({
    super.key,
    required this.invitation,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final clientData = invitation.clientData;
    final studioName = clientData?.name ?? 'Studio';
    final initials = clientData?.initials ?? 'ST';
    final email = clientData?.email ?? '';

    return Container(
      margin: EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : AppColors.surfaceElevated),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2),
        ),
        boxShadow:
            AppShadows.soft(AppColors.primary, opacity: 0.04, blur: 16, y: 8),
      ),
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7C5CFF), Color(0xFFA855F7)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Studio Invitation',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        studioName,
                        style: TextStyle(
                          color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (email.isNotEmpty) ...[
                        SizedBox(height: 2),
                        Text(
                          email,
                          style: TextStyle(
                            color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hourglass_empty_rounded,
                          size: 12, color: AppColors.primary),
                      SizedBox(width: 4),
                      Text(
                        'Pending',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.lg),
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: onAccept,
                      icon: Icon(Icons.check_rounded, size: 18),
                      label: Text(
                        'Accept',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: onReject,
                      icon: Icon(Icons.close_rounded, size: 18),
                      label: Text(
                        'Decline',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RejectedInviteCard extends StatelessWidget {
  final StudioClientConnection invitation;

  const _RejectedInviteCard({super.key, required this.invitation});

  @override
  Widget build(BuildContext context) {
    final clientData = invitation.clientData;
    final studioName = clientData?.name ?? 'Studio';

    return Container(
      margin: EdgeInsets.only(bottom: AppSpacing.sm),
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: (Theme.of(context).brightness == Brightness.dark ? AppColors.darkSurfaceRaised : AppColors.surfaceElevated),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.cancel_rounded,
                color: AppColors.error, size: 18),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  studioName,
                  style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Invitation declined',
                  style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Declined',
              style: TextStyle(
                color: AppColors.error,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
