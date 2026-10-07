import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/zip_job_model.dart';
import 'auth_providers.dart' show apiClientProvider;

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

class ZipJobRepository {
  ZipJobRepository({required this.apiClient});

  final dynamic apiClient; // ApiClient

  Future<ZipJobModel> createJob({
    required String kind, // 'zip_folder' | 'zip_album'
    required String targetId,
  }) async {
    final json = await apiClient.post('/zip-jobs', body: {
      'kind': kind,
      'target_id': targetId,
    }) as Map<String, dynamic>;
    return ZipJobModel.fromJson(json);
  }

  Future<ZipJobModel> getJob(String jobId) async {
    final json =
        await apiClient.get('/zip-jobs/$jobId') as Map<String, dynamic>;
    return ZipJobModel.fromJson(json);
  }

  Future<List<ZipJobModel>> listJobs() async {
    final list = await apiClient.get('/zip-jobs') as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(ZipJobModel.fromJson)
        .toList();
  }

  Future<void> cancelJob(String jobId) async {
    await apiClient.delete('/zip-jobs/$jobId');
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final zipJobRepositoryProvider = Provider<ZipJobRepository>((ref) {
  return ZipJobRepository(apiClient: ref.watch(apiClientProvider));
});

/// Holds the list of the user's recent zip jobs.
final zipJobsProvider =
    StateNotifierProvider<ZipJobsController, AsyncValue<List<ZipJobModel>>>(
  (ref) => ZipJobsController(ref),
);

class ZipJobsController
    extends StateNotifier<AsyncValue<List<ZipJobModel>>> {
  ZipJobsController(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  final Ref _ref;
  Timer? _pollTimer;

  ZipJobRepository get _repo => _ref.read(zipJobRepositoryProvider);

  Future<void> _load() async {
    try {
      final jobs = await _repo.listJobs();
      if (mounted) state = AsyncValue.data(jobs);
      _schedulePollingIfNeeded(jobs);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  void _schedulePollingIfNeeded(List<ZipJobModel> jobs) {
    final hasActive = jobs.any((j) => j.isActive);
    if (hasActive && _pollTimer == null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollActive());
    } else if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _pollActive() async {
    final current = state.valueOrNull;
    if (current == null) return;

    final updated = <ZipJobModel>[];
    for (final job in current) {
      if (job.isActive) {
        try {
          final refreshed = await _repo.getJob(job.id);
          updated.add(refreshed);
        } catch (_) {
          updated.add(job);
        }
      } else {
        updated.add(job);
      }
    }
    if (mounted) {
      state = AsyncValue.data(updated);
      _schedulePollingIfNeeded(updated);
    }
  }

  /// Queue a new ZIP job for a folder or album.
  Future<ZipJobModel> createJob({
    required String kind,
    required String targetId,
  }) async {
    final job = await _repo.createJob(kind: kind, targetId: targetId);
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([job, ...current]);
    _schedulePollingIfNeeded([job, ...current]);
    return job;
  }

  Future<void> cancelJob(String jobId) async {
    await _repo.cancelJob(jobId);
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(
      current
          .map((j) => j.id == jobId
              ? ZipJobModel(
                  id: j.id,
                  kind: j.kind,
                  status: ZipJobStatus.canceled,
                  progress: j.progress,
                  resultUrl: j.resultUrl,
                  errorMessage: j.errorMessage,
                  createdAt: j.createdAt,
                  updatedAt: DateTime.now().toUtc(),
                  expiresAt: j.expiresAt,
                )
              : j)
          .toList(),
    );
  }

  Future<void> refresh() => _load();

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
