import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/admin_dashboard_repository.dart';
import '../data/api_admin_dashboard_repository.dart';
import '../models/admin_dashboard_data.dart';
import 'auth_providers.dart';

/// Swap this single line to point the whole Admin Dashboard at a real
/// backend later (Django API, Firebase, REST, etc.) — nothing else in
/// the app needs to change since every screen only depends on
/// [AdminDashboardRepository]. Now pointed at [ApiAdminDashboardRepository]
/// (Task 20.6/20.7) — same `currentUserId` callback pattern
/// [studio_client_connections_provider.dart]'s `ApiConnectionsRepository`
/// already uses, so it always reads whoever is currently logged in
/// rather than capturing a stale id at provider-creation time.
final adminDashboardRepositoryProvider =
    Provider<AdminDashboardRepository>((ref) {
  return ApiAdminDashboardRepository(
    apiClient: ref.watch(apiClientProvider),
    currentUserId: () => ref.read(authStateProvider).user?.id ?? '',
    studioName: () => ref.read(authStateProvider).user?.studioName ?? '',
    photographerName: () => ref.read(authStateProvider).user?.fullName ?? '',
  );
});

/// Async, mutable dashboard state. The screen watches this and reacts to
/// loading / data / error automatically — there is no compile-time data
/// anywhere in the widget tree. Every mutation below re-fetches through
/// the repository, which also persists to on-device storage, so the
/// dashboard survives an app restart.
final adminDashboardProvider =
    AsyncNotifierProvider<AdminDashboardNotifier, AdminDashboardSnapshot>(
        AdminDashboardNotifier.new);

class AdminDashboardNotifier extends AsyncNotifier<AdminDashboardSnapshot> {
  AdminDashboardRepository get _repo =>
      ref.read(adminDashboardRepositoryProvider);

  @override
  Future<AdminDashboardSnapshot> build() async {
    // Watch authStateProvider so the dashboard invalidates and fetches
    // fresh data when switching accounts.
    ref.watch(authStateProvider);
    return _repo.fetchSnapshot();
  }

  /// Pull-to-refresh / retry-after-error.
  Future<void> refresh() async {
    final current = state.valueOrNull;
    if (current != null) {
      try {
        final newData = await _repo.fetchSnapshot();
        state = AsyncData(newData);
      } catch (e, st) {
        state = AsyncError(e, st);
      }
    } else {
      state = const AsyncLoading<AdminDashboardSnapshot>().copyWithPrevious(state);
      state = await AsyncValue.guard(_repo.fetchSnapshot);
    }
  }

  /// These three mutations update `state` in place (optimistic, rolled
  /// back on failure) instead of calling [refresh] — which re-fetches
  /// the *whole* dashboard (clients/uploads/analytics/notifications)
  /// through `AsyncValue.guard`, briefly putting `state` into
  /// `AsyncLoading` and flashing the entire Notifications screen to a
  /// spinner for what should be a single-row change. This mirrors
  /// `AlertsController`'s optimistic-update-with-rollback pattern for
  /// the same underlying `/notifications` endpoints.

  Future<void> markNotificationRead(String id) async {
    final snapshot = state.valueOrNull;
    if (snapshot == null) return;
    final idx = snapshot.notifications.indexWhere((n) => n.id == id);
    if (idx == -1 || snapshot.notifications[idx].isRead) return;

    final previous = snapshot.notifications;
    final updated = [...previous];
    updated[idx] = updated[idx].copyWith(isRead: true);
    state = AsyncData(snapshot.copyWith(notifications: updated));

    try {
      await _repo.markNotificationRead(id);
    } catch (_) {
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncData(current.copyWith(notifications: previous));
      }
      rethrow;
    }
  }

  Future<void> markAllNotificationsRead() async {
    final snapshot = state.valueOrNull;
    if (snapshot == null) return;
    final previous = snapshot.notifications;
    if (previous.every((n) => n.isRead)) return;

    final updated = previous.map((n) => n.copyWith(isRead: true)).toList();
    state = AsyncData(snapshot.copyWith(notifications: updated));

    try {
      await _repo.markAllNotificationsRead();
    } catch (_) {
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncData(current.copyWith(notifications: previous));
      }
      rethrow;
    }
  }

  Future<void> deleteNotification(String id) async {
    final snapshot = state.valueOrNull;
    if (snapshot == null) return;
    final idx = snapshot.notifications.indexWhere((n) => n.id == id);
    if (idx == -1) return;

    final previous = snapshot.notifications;
    final updated = [...previous]..removeAt(idx);
    // Removing the row from `state` on this same frame — rather than
    // only after the network call below resolves — is what a
    // Dismissible needs: it requires the dismissed item to actually
    // leave the tree immediately, or Flutter throws "A dismissed
    // Dismissible widget is still part of the tree."
    state = AsyncData(snapshot.copyWith(notifications: updated));

    try {
      await _repo.deleteNotification(id);
    } catch (_) {
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncData(current.copyWith(notifications: previous));
      }
      rethrow;
    }
  }

  Future<void> addClient(
      {required String name, required String initials}) async {
    await _repo.addClient(name: name, initials: initials);
    await refresh();
  }

  Future<void> removeClient(String clientId) async {
    await _repo.removeClient(clientId);
    await refresh();
  }

  Future<void> assignGalleriesToClient(
      String clientId, List<String> galleryIds) async {
    await _repo.assignGalleriesToClient(clientId, galleryIds);
    await refresh();
  }

  Future<void> inviteClient({
    required String name,
    required String email,
    required double bookingValue,
  }) async {
    await _repo.inviteClient(
      name: name,
      email: email,
      bookingValue: bookingValue,
    );
    await refresh();
  }

  Future<void> addUpload(
      {required String albumName, required bool isVideo}) async {
    await _repo.addUpload(albumName: albumName, isVideo: isVideo);
    await refresh();
  }

  Future<void> pushNotification({
    required NotificationType type,
    required String title,
    required String subtitle,
  }) async {
    await _repo.pushNotification(type: type, title: title, subtitle: subtitle);
    await refresh();
  }

  Future<void> shareGallery({required String albumName}) async {
    await _repo.shareGallery(albumName: albumName);
    await refresh();
  }

  /// Returns the generated report summary so the caller can show it
  /// (e.g. in a dialog) immediately, while the dashboard state (and its
  /// new Activity Timeline entry) refreshes underneath.
  Future<String> generateReport() async {
    final summary = await _repo.generateReport();
    await refresh();
    return summary;
  }

  Future<void> resetToSeedData() async {
    await _repo.resetToSeedData();
    await refresh();
  }

  void updateMediaCounts({required int photoCount, required int videoCount, required int totalSizeBytes}) {
    // The snapshot does not expose individual media-count fields directly;
    // trigger a background refresh so the dashboard stat cards stay in sync.
    refresh();
  }
}
