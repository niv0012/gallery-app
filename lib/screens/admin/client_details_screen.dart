import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/admin_dashboard_data.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/admin_dashboard_providers.dart';
import '../../providers/album_provider.dart';
import '../../providers/auth_providers.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../media/media_grid_screen.dart';
import '../../core/theme/theme_context.dart';

// Deterministic gradient picker matching DashboardClientDto._gradientFor —
// used when a ClientData is built from connectionsProvider (no gradient set).
const List<List<Color>> _kGradients = [
  [Color(0xFF7C5CFF), Color(0xFFA855F7)],
  [Color(0xFFEC4899), Color(0xFFF472B6)],
  [Color(0xFFA855F7), Color(0xFFEC4899)],
  [Color(0xFF22C55E), Color(0xFF7C5CFF)],
];

List<Color> _gradientFor(String id) =>
    _kGradients[id.hashCode.abs() % _kGradients.length];

class ClientDetailsScreen extends ConsumerStatefulWidget {
  final String clientId;

  const ClientDetailsScreen({super.key, required this.clientId});

  @override
  ConsumerState<ClientDetailsScreen> createState() =>
      _ClientDetailsScreenState();
}

class _ClientDetailsScreenState extends ConsumerState<ClientDetailsScreen> {
  void _showAssignGalleriesDialog(ClientData client) {
    final allAlbums = ref.read(albumProvider).allAlbums;
    final selectedIds = List<String>.from(client.assignedGalleryIds);

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.darkSurface
                  : AppColors.surface),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Text(
                'Assign Galleries',
                style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                    fontWeight: FontWeight.bold,
                    fontSize: 18),
              ),
              content: allAlbums.isEmpty
                  ? Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'No albums available in the system.',
                        style: TextStyle(
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle),
                            fontSize: 14),
                      ),
                    )
                  : SizedBox(
                      width: double.maxFinite,
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: allAlbums.length,
                        itemBuilder: (context, index) {
                          final album = allAlbums[index];
                          final isSelected = selectedIds.contains(album.id);
                          return CheckboxListTile(
                            activeColor: AppColors.primary,
                            checkColor: Colors.white,
                            title: Text(album.name,
                                style: TextStyle(
                                    color: (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.textOnDark
                                        : AppColors.text),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                '${album.photoCount} photos • ${album.videoCount} videos',
                                style: TextStyle(
                                    color: (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.subtitleOnDark
                                        : AppColors.subtitle),
                                    fontSize: 11)),
                            value: isSelected,
                            onChanged: (val) {
                              setStateDialog(() {
                                if (val == true) {
                                  selectedIds.add(album.id);
                                } else {
                                  selectedIds.remove(album.id);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel',
                      style: TextStyle(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          fontWeight: FontWeight.w600)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(context);
                    await ref
                        .read(adminDashboardProvider.notifier)
                        .assignGalleriesToClient(
                          client.id,
                          selectedIds,
                        );
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                            content: Text('Galleries updated successfully')),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text('Save',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dashboardAsync = ref.watch(adminDashboardProvider);
    final studioId = ref.watch(authStateProvider).user?.id ?? '';
    final connections = ref.watch(connectionsProvider).valueOrNull ?? [];
    final connection = connections.cast<StudioClientConnection?>().firstWhere(
          (c) =>
              c?.clientId == widget.clientId &&
              c?.studioId == studioId &&
              c?.status == ConnectionStatus.connected,
          orElse: () => null,
        );

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textOnDark
                  : AppColors.text),
              size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Client Details',
          style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textOnDark
                  : AppColors.text),
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2),
        ),
        centerTitle: true,
        actions: [
          if (connection != null)
            IconButton(
              icon: Icon(Icons.person_remove_rounded, color: AppColors.error),
              tooltip: 'Remove Client',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Remove Client?'),
                    content: Text(
                        'Are you sure you want to remove this connected client? They will lose access to any private albums you shared with them.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel')),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text('Remove',
                            style: TextStyle(
                                color: AppColors.error,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                );

                if (confirm == true && context.mounted) {
                  try {
                    await ref
                        .read(connectionsProvider.notifier)
                        .disconnect(connection.id);
                    if (context.mounted) {
                      Navigator.pop(context); // Go back to Clients list
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Client removed successfully.')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('Error: $e'),
                            backgroundColor: AppColors.error),
                      );
                    }
                  }
                }
              },
            ),
        ],
      ),
      body: dashboardAsync.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: AppColors.primary)),
        error: (err, _) => Center(
            child: Text('Error loading details: $err',
                style: TextStyle(color: AppColors.error))),
        data: (snapshot) {
          // Primary lookup: from the dashboard snapshot's clients list.
          ClientData? client = snapshot.clients.cast<ClientData?>().firstWhere(
                (c) => c?.id == widget.clientId,
                orElse: () => null,
              );

          // Fallback: if the dashboard snapshot hasn't loaded this client yet
          // (e.g. first load, or dashboard cache is stale), build a ClientData
          // directly from the live connectionsProvider instead so the details
          // screen never shows "Client not found" for a client that really is
          // connected.
          if (client == null) {
            final studioId = ref.read(authStateProvider).user?.id ?? '';
            final connections = ref.read(connectionsProvider).valueOrNull ?? [];
            final conn = connections.cast<StudioClientConnection?>().firstWhere(
                  (c) =>
                      c?.clientId == widget.clientId &&
                      c?.studioId == studioId &&
                      c?.status == ConnectionStatus.connected,
                  orElse: () => null,
                );
            final cd = conn?.clientData;
            if (cd != null) {
              client = ClientData(
                id: cd.id,
                name: cd.name,
                initials: cd.initials,
                gradient:
                    cd.gradient.isNotEmpty ? cd.gradient : _gradientFor(cd.id),
                bookingStatus: 'Connected',
                galleryStatus: cd.galleryStatus,
                outstanding: cd.outstanding,
                isPaid: cd.isPaid,
                bookingValue: cd.bookingValue,
                email: cd.email,
                lastActive: conn!.respondedAt ?? conn.requestedAt,
                assignedGalleryIds: cd.assignedGalleryIds,
                totalViews: cd.totalViews,
                totalDownloads: cd.totalDownloads,
                activityLog: cd.activityLog,
              );
            }
          }

          if (client == null) {
            return Center(
              child: Text(
                'Client not found or was removed.',
                style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                    fontSize: 15),
              ),
            );
          }

          // Promote to non-nullable — the early return above guarantees client != null here.
          final c = client;

          final allAlbums = ref.watch(albumProvider).allAlbums;
          final assignedAlbums = allAlbums
              .where((album) => c.assignedGalleryIds.contains(album.id))
              .toList();

          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header profile card
                Container(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.darkSurfaceRaised
                        : AppColors.surfaceElevated),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: context.borderColor),
                    boxShadow: AppShadows.soft(AppColors.primary,
                        opacity: 0.05, blur: 20, y: 8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: c.gradient,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          c.initials,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 22,
                          ),
                        ),
                      ),
                      SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.name,
                              style: TextStyle(
                                color: (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.textOnDark
                                    : AppColors.text),
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              c.email.isNotEmpty
                                  ? c.email
                                  : 'No email provided',
                              style: TextStyle(
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.subtitleOnDark
                                      : AppColors.subtitle),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: AppSpacing.lg),

                // Stat boxes
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.visibility_rounded,
                        label: 'Gallery Views',
                        value: '${c.totalViews}',
                        gradient: const [Color(0xFF7C5CFF), Color(0xFFA855F7)],
                      ),
                    ),
                    SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.download_rounded,
                        label: 'Downloads',
                        value: '${c.totalDownloads}',
                        gradient: const [Color(0xFFEC4899), Color(0xFFF472B6)],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: AppSpacing.lg),

                // Details list card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.darkSurfaceRaised
                        : AppColors.surfaceElevated),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Column(
                    children: [
                      _DetailRow(
                        icon: Icons.payments_rounded,
                        label: 'Outstanding Payment',
                        value: c.outstanding,
                        valueColor:
                            c.isPaid ? AppColors.success : AppColors.error,
                      ),
                      Divider(color: context.borderColor, height: 24),
                      _DetailRow(
                        icon: Icons.access_time_filled_rounded,
                        label: 'Last Active',
                        value: c.lastActive != null
                            ? relativeTime(c.lastActive!)
                            : 'Never',
                      ),
                    ],
                  ),
                ),

                SizedBox(height: AppSpacing.lg),
                // Client Selections action
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(
                            title: Text('Liked by ${c.name}',
                                style: TextStyle(
                                    color: (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.textOnDark
                                        : AppColors.text),
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800)),
                            leading: IconButton(
                              icon: Icon(Icons.arrow_back_ios_new_rounded,
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                                  size: 20),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                          body: SafeArea(
                            child: MediaGridScreen(
                              likedByClientId: c.id,
                              showBack: false,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.favorite_rounded,
                              color: Colors.white, size: 20),
                        ),
                        SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'View Client Selections',
                                style: TextStyle(
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'See all photos and videos this client has liked',
                                style: TextStyle(
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.subtitleOnDark
                                      : AppColors.subtitle),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle)),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: AppSpacing.lg),

                // Shared Galleries Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Assigned Galleries',
                      style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text),
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.1,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _showAssignGalleriesDialog(c),
                      icon: Icon(Icons.add_link_rounded,
                          size: 18, color: AppColors.primary),
                      label: Text(
                        'Assign',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: AppSpacing.xs),

                if (assignedAlbums.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                    decoration: BoxDecoration(
                      color: context.surfaceColor.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: context.borderColor, style: BorderStyle.none),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      children: [
                        Icon(Icons.link_off_rounded,
                            color: context.textMuted.withValues(alpha: 0.5),
                            size: 40),
                        SizedBox(height: 12),
                        Text(
                          'No galleries assigned yet.',
                          style: TextStyle(
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: assignedAlbums.length,
                    itemBuilder: (context, index) {
                      final album = assignedAlbums[index];
                      return Container(
                        margin: EdgeInsets.only(bottom: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.darkSurfaceRaised
                                  : AppColors.surfaceElevated),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.md, vertical: 4),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.photo_library_rounded,
                                color: AppColors.primary, size: 20),
                          ),
                          title: Text(
                            album.name,
                            style: TextStyle(
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.textOnDark
                                  : AppColors.text),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${album.photoCount} photos • ${album.videoCount} videos',
                            style: TextStyle(
                                color: (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle),
                                fontSize: 11.5),
                          ),
                          trailing: Icon(Icons.chevron_right_rounded,
                              color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                              size: 20),
                          onTap: () {
                            Navigator.pushNamed(
                              context,
                              '/admin/albums/details',
                              arguments: album.id,
                            );
                          },
                        ),
                      );
                    },
                  ),
                SizedBox(height: AppSpacing.xl),

                // Client Activity timeline
                Text(
                  'Client Activity',
                  style: TextStyle(
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
                SizedBox(height: AppSpacing.md),

                if (c.activityLog.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(vertical: 24),
                    alignment: Alignment.center,
                    child: Text(
                      'No recent activity recorded.',
                      style: TextStyle(
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.subtitleOnDark
                                  : AppColors.subtitle),
                          fontSize: 13),
                    ),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: c.activityLog.length,
                    itemBuilder: (context, index) {
                      final log = c.activityLog[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: EdgeInsets.only(top: 4, right: 12),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                log,
                                style: TextStyle(
                                  color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final List<Color> gradient;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: (Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurfaceRaised
            : AppColors.surfaceElevated),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            value,
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textOnDark
                  : AppColors.text),
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            color: (Theme.of(context).brightness == Brightness.dark
                ? AppColors.subtitleOnDark
                : AppColors.subtitle),
            size: 18),
        SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            color: (Theme.of(context).brightness == Brightness.dark
                ? AppColors.subtitleOnDark
                : AppColors.subtitle),
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ??
                  (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text),
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
