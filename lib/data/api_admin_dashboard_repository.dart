import 'package:flutter/material.dart';

import '../core/network/api_client.dart';
import '../models/admin_dashboard_data.dart';
import '../models/album_model.dart';
import '../repositories/notifications_repository.dart';
import 'admin_dashboard_dto.dart';
import 'admin_dashboard_repository.dart';

/// `/admin-dashboard/stats`, `/connections`, `/media`,
/// `/notifications`, `/activity-log`, `/admin-dashboard/analytics`, and
/// `/albums` endpoints via [ApiClient] — same one-repository-per-screen
/// convention as [ApiConnectionsRepository]/[ApiBookingRepository],
/// mapped through the [DashboardStatsDto]/
/// [DashboardClientDto]/[DashboardUploadsDto]/[DashboardNotificationDto]/
/// [DashboardActivityLogDto]/[DashboardAnalyticsDto] DTOs
/// (`admin_dashboard_dto.dart`, Task 20.5). `/albums` (added alongside
/// this fix) resolves each Recent Uploads group to its real name rather
/// than [DashboardUploadsDto]'s id-prefix placeholder.
///
/// [fetchSnapshot] (Task 20.6) replaces
/// [InMemoryAdminDashboardRepository]'s fabricated snapshot with the
/// studio's real data. [AdminDashboardSnapshot.activityLog] (Task 20.9)
/// and `.analytics` (Task 20.10) now come from `/activity-log` and
/// `/admin-dashboard/analytics` respectively, same batch of calls as
/// everything else here.
///
/// The write side (Task 20.7) wires up every mutation that has a real
/// endpoint behind it — notification read/unread/delete and
/// api_connections_repository.dart, and generateReport is computed
/// purely off a fresh fetchSnapshot, same as the in-memory version. The
/// rest genuinely have no purpose-built endpoint yet (no
/// `POST /admin-dashboard/clients`, no `DELETE /connections/{id}`, no
/// gallery-share route, ...) — same pattern [ApiStudioRepository]
/// already uses for the studio directory it doesn't back — so they
/// still throw [UnimplementedError] pointing at whichever real
/// repository/endpoint actually owns that action, or at the future
/// task that should wire it up.
///
/// Note: Quick Actions (Task 20.11) are an entirely client-side feature
/// mapping fixed shortcut tiles to app screens — there is no backend
/// endpoint for them.

const List<QuickActionData> _kDefaultQuickActions = [
  QuickActionData(
    id: 'upload_photos',
    icon: Icons.add_photo_alternate_rounded,
    label: 'Upload\nPhotos',
    gradient: [Color(0xFF7C5CFF), Color(0xFFA855F7)],
  ),
  QuickActionData(
    id: 'upload_videos',
    icon: Icons.video_call_rounded,
    label: 'Upload\nVideos',
    gradient: [Color(0xFFEC4899), Color(0xFFF472B6)],
  ),
  QuickActionData(
    id: 'create_album',
    icon: Icons.create_new_folder_rounded,
    label: 'Create\nAlbum',
    gradient: [Color(0xFF22C55E), Color(0xFF10B981)],
  ),
  QuickActionData(
    id: 'add_client',
    icon: Icons.person_add_rounded,
    label: 'Add\nClient',
    gradient: [Color(0xFFF59E0B), Color(0xFFEF4444)],
  ),
  QuickActionData(
    id: 'share_gallery',
    icon: Icons.share_rounded,
    label: 'Share\nGallery',
    gradient: [Color(0xFF0EA5E9), Color(0xFF3B82F6)],
  ),
  QuickActionData(
    id: 'reports',
    icon: Icons.analytics_rounded,
    label: 'View\nReports',
    gradient: [Color(0xFF8B5CF6), Color(0xFFD946EF)],
  ),
  QuickActionData(
    id: 'show_qr',
    icon: Icons.qr_code_rounded,
    label: 'Show\nMy QR',
    gradient: [Color(0xFF14B8A6), Color(0xFF06B6D4)],
  ),
];

class ApiAdminDashboardRepository implements AdminDashboardRepository {
  ApiAdminDashboardRepository({
    required ApiClient apiClient,
    required String Function() currentUserId,
    String Function()? studioName,
    String Function()? photographerName,
  })  : _apiClient = apiClient,
        _currentUserId = currentUserId,
        _studioName = studioName,
        _photographerName = photographerName,
        _notificationsRepo = NotificationsRepository(apiClient: apiClient);

  final ApiClient _apiClient;
  final String Function() _currentUserId;

  /// Thin wrappers this class delegates the write-side to, rather than
  /// duplicating their HTTP calls — same endpoints
  /// `NotificationsRepository` already wires up
  /// for the Notifications screen.
  final NotificationsRepository _notificationsRepo;

  /// `studioName`/`photographerName` aren't in this task's endpoint list
  /// either (they'd come from `GET /users/me`) — callers that already
  /// have the logged-in studio's profile (e.g. off `AuthNotifier`) can
  /// pass it in here; otherwise this falls back to an empty string
  /// rather than a fabricated placeholder name.
  final String Function()? _studioName;
  final String Function()? _photographerName;

  @override
  Future<AdminDashboardSnapshot> fetchSnapshot() async {
    final results = await Future.wait([
      _apiClient.get('/admin-dashboard/stats'),
      _apiClient.get('/connections'),
      _apiClient.get('/media'),
      _apiClient.get('/notifications'),
      // Task 20.9/20.10: Recent Activity and the Analytics carousel now
      // read from their real endpoints too, same as everything above —
      // both added to this same Future.wait batch rather than a
      // separate round-trip.
      _apiClient.get('/activity-log'),
      _apiClient.get('/admin-dashboard/analytics'),
      // Recent Uploads groups `/media` rows by `albumId`, but MediaRead
      // never carries the album's name — only its id. Without this,
      // every group falls back to DashboardUploadsDto's "Album
      // <id-prefix>" placeholder even for perfectly real, named albums.
      // Same `/albums` list ApiAlbumRepository already uses elsewhere,
      // added to this batch rather than a separate round-trip.
      _apiClient.get('/albums'),
      // Per-client download counts (Views/Downloads analytics tabs).
      // Returns only rows with at least one event, so missing = zero.
      _apiClient.get('/admin-dashboard/client-stats'),
    ]);

    final statsJson = results[0] as Map<String, dynamic>;
    final connectionsJson = results[1] as List<dynamic>;
    // /media returns a paginated MediaPageRead object {items, total_count, next_cursor},
    // not a bare list — extract the 'items' array to get the actual media list.
    final mediaRaw = results[2];
    final mediaJson = mediaRaw is List
        ? mediaRaw
        : (mediaRaw as Map<String, dynamic>)['items'] as List<dynamic>? ?? <dynamic>[];
    final notificationsJson = results[3] as List<dynamic>;
    final activityLogJson = results[4] as Map<String, dynamic>;
    final analyticsJson = results[5] as Map<String, dynamic>;
    final albumsJson = results[6] as List<dynamic>;
    final clientStatsJson = results[7] as Map<String, dynamic>;

    // Build a clientId -> {views, downloads} lookup from the client-stats
    // response so we can merge real numbers into each ClientData below.
    final clientStatsItems =
        (clientStatsJson['items'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
    final downloadsByClientId = <String, int>{
      for (final item in clientStatsItems)
        item['client_id'] as String:
            (item['total_downloads'] as num?)?.toInt() ?? 0,
    };
    final viewsByClientId = <String, int>{
      for (final item in clientStatsItems)
        item['client_id'] as String:
            (item['total_views'] as num?)?.toInt() ?? 0,
    };
    final galleriesByClientId = <String, List<String>>{
      for (final item in clientStatsItems)
        item['client_id'] as String:
            (item['assigned_gallery_ids'] as List<dynamic>? ?? [])
                .cast<String>(),
    };

    final currentUserId = _currentUserId();

    final connectionDtos = connectionsJson
        .map((e) => DashboardClientDto.fromApiJson(
              e as Map<String, dynamic>,
              currentUserId: currentUserId,
            ))
        .toList(growable: false);

    final clients = connectionDtos
        .where((dto) => dto.isActiveClient)
        .map((dto) {
          final cd = dto.toClientData();
          if (cd == null) return null;
          final views = viewsByClientId[cd.id] ?? 0;
          final downloads = downloadsByClientId[cd.id] ?? 0;
          final assignedGalleries = galleriesByClientId[cd.id] ?? const [];
          if (views == 0 && downloads == 0 && assignedGalleries.isEmpty) {
            return cd;
          }
          return cd.copyWith(
            totalViews: views,
            totalDownloads: downloads,
            assignedGalleryIds: assignedGalleries,
          );
        })
        .whereType<ClientData>()
        .toList(growable: false);

    final albums = albumsJson
        .map((e) => AlbumModel.fromApiJson(e as Map<String, dynamic>))
        .toList(growable: false);
    final recentUploads = DashboardUploadsDto.fromApiJson(mediaJson)
        .toAlbumUploads(albums: albums);

    final notifications = notificationsJson
        .map((e) =>
            DashboardNotificationDto.fromApiJson(e as Map<String, dynamic>)
                .toNotificationData())
        .toList(growable: false);

    final activityLog =
        DashboardActivityLogDto.fromApiJson(activityLogJson).toActivityLog();
    final analytics =
        DashboardAnalyticsDto.fromApiJson(analyticsJson).toAnalyticsSeries();

    final stats = DashboardStatsDto.fromApiJson(statsJson);

    return AdminDashboardSnapshot(
      studioName: _studioName?.call() ?? '',
      photographerName: _photographerName?.call() ?? '',
      stats: stats.toStatCards(),
      quickActions: _kDefaultQuickActions,
      recentUploads: recentUploads,
      clients: clients,
      analytics: analytics,
      notifications: notifications,
      activityLog: activityLog,
      sharedGalleryCount: stats.sharedGalleryCount,
      totalGalleryViews: stats.totalGalleryViews,
      totalGalleryDownloads: stats.totalGalleryDownloads,
    );
  }

  // -----------------------------------------------------------------
  // Write side (Task 20.7). Four of these have a real endpoint behind
  // them and are wired up for real below, by delegating to the same
  // repositories (NotificationsRepository/ApiBookingRepository) that
  // already own those endpoints elsewhere in the app, instead of
  // duplicating their HTTP calls here. generateReport also becomes
  // real further down — it never needed its own endpoint, only live
  // data, exactly like InMemoryAdminDashboardRepository.generateReport
  // computes it purely off fetchSnapshot().
  //
  // The rest (addClient/inviteClient/removeClient/addUpload/
  // pushNotification/shareGallery) still throw UnimplementedError:
  // there genuinely is no endpoint for them yet (no client-creation
  // route, no DELETE /connections/{id}, no client-triggered
  // notification-create route, no gallery-share route, and addUpload
  // has no file bytes to send in the first place) — see each method's
  // message for the real endpoint/task that does/should own it.
  // -----------------------------------------------------------------

  @override
  Future<void> markNotificationRead(String notificationId) {
    return _notificationsRepo.markAsRead(notificationId);
  }

  @override
  Future<void> markAllNotificationsRead() {
    return _notificationsRepo.markAllAsRead();
  }

  @override
  Future<void> deleteNotification(String notificationId) {
    return _notificationsRepo.deleteOne(notificationId);
  }

  @override
  Future<ClientData> addClient(
      {required String name, required String initials}) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet, and there is no '
      '"create client" endpoint — clients only ever come from an '
      'accepted /connections invite.',
    );
  }

  @override
  Future<void> removeClient(String clientId) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet, and there is no '
      'DELETE /connections/{id} endpoint yet.',
    );
  }

  @override
  Future<void> assignGalleriesToClient(
      String clientId, List<String> galleryIds) async {
    // 1. Fetch current active shares for this client
    final currentSharesResponse =
        await _apiClient.get('/studio/shares?client_id=$clientId');
    final currentShares =
        (currentSharesResponse as List<dynamic>).cast<Map<String, dynamic>>();

    final currentAlbumIds = <String, String>{}; // Maps album_id -> share_id
    for (final share in currentShares) {
      currentAlbumIds[share['album_id'] as String] = share['id'] as String;
    }

    final desiredSet = galleryIds.toSet();
    final currentSet = currentAlbumIds.keys.toSet();

    final toAdd = desiredSet.difference(currentSet);
    final toRemove = currentSet.difference(desiredSet);

    // 2. Add new shares
    for (final albumId in toAdd) {
      await _apiClient.post('/studio/shares', body: {
        'album_id': albumId,
        'client_id': clientId,
      });
    }

    // 3. Revoke removed shares
    for (final albumId in toRemove) {
      final shareId = currentAlbumIds[albumId]!;
      await _apiClient.delete('/studio/shares/$shareId');
    }
  }

  @override
  Future<ClientData> inviteClient({
    required String name,
    required String email,
    required double bookingValue,
  }) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet — use '
      'ApiConnectionsRepository.inviteClient (POST /connections/invite) instead.',
    );
  }

  @override
  Future<AlbumUploadData> addUpload(
      {required String albumName, required bool isVideo}) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet — real uploads go '
      'through MediaUploadService / ApiMediaRepository.uploadMedia '
      '(POST /media/upload), which needs actual file bytes this method '
      'never receives.',
    );
  }

  @override
  Future<NotificationData> pushNotification({
    required NotificationType type,
    required String title,
    required String subtitle,
  }) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet, and there is no '
      'client-triggered "create notification" endpoint — notifications '
      'are only ever created as a side effect of another action '
      'server-side.',
    );
  }

  @override
  Future<void> shareGallery({required String albumName}) {
    throw UnimplementedError(
      'ApiAdminDashboardRepository does not back this yet — no gallery-share '
      'endpoint is wired up yet.',
    );
  }

  @override
  Future<String> generateReport() async {
    // No dedicated report-generation endpoint exists — same as
    // InMemoryAdminDashboardRepository.generateReport, this only ever
    // needed a fresh read of the live data, which fetchSnapshot()
    // already provides.
    final snapshot = await fetchSnapshot();
    final photosStat =
        snapshot.stats.firstWhere((s) => s.label == 'Total Photos');
    return 'Photos ${photosStat.value} • '
        'Clients ${snapshot.clients.length}';
  }

  @override
  Future<void> resetToSeedData() {
    throw UnimplementedError(
      'ApiAdminDashboardRepository talks to the real backend — there is '
      'no seed data to reset to.',
    );
  }
}
