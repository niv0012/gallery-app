import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../repositories/media_repository.dart';
import '../models/media_model.dart';
import '../providers/album_provider.dart';
import '../providers/auth_providers.dart';
import '../providers/media_provider.dart';
import '../providers/admin_dashboard_providers.dart';
import '../services/media_picker_service.dart' show MediaContentType;
import '../services/upload_foreground_service.dart';
import '../storage/upload_queue_local_store.dart';

import 'upload_job_model.dart';
import 'picked_file_info.dart';
import 'upload_network_gate.dart';
import 'upload_queue_state.dart';

/// Controller/notifier for the Upload Queue.
///
/// Task 19.11: progress bars are now driven by the real
/// `onSendProgress(sent, total)` callback from [MediaRepository.uploadMedia]
/// (`MediaUploadService` under the hood, Task 19.5/19.9) instead of a
/// time-based simulation. A queued job's real upload — file read + network
/// request — kicks off the moment it's picked off the queue, and every
/// progress tick from the socket is written straight onto that job's
/// `uploadedBytes`/`totalBytes`, so the tile the user sees
/// ([UploadQueueTile]) reflects bytes actually in flight, not a guess.
/// Options configuration, pausing/resuming/cancelling, Hive storage, and
/// automated refresh of the gallery/media providers are unchanged.
class UploadQueueController extends AsyncNotifier<UploadQueueState> {
  Timer? _ticker;

  /// Read fresh each time rather than cached in a field — this queue can
  /// outlive a single repository instance (e.g. `apiClientProvider`
  /// rebuilding), and always going through Riverpod keeps this on the
  /// same API-backed [MediaRepository] (Task 19.9) as the rest of the
  /// app instead of a hardcoded local one.
  MediaRepository get _mediaRepo => ref.read(mediaRepositoryProvider);

  final UploadQueueLocalStore _localStore = UploadQueueLocalStore();

  /// How many uploads may run in parallel. 2 is a good balance between
  /// throughput and avoiding server rate-limiting / OOM on web.
  static const int _maxConcurrentUploads = 2;

  /// Ids of jobs whose real upload (file read + network request) is currently
  /// in flight. Up to [_maxConcurrentUploads] may be active at once.
  final Set<String> _inFlightJobIds = {};
  final Map<String, CancelToken> _uploadCancelTokens = {};

  /// Cached result of [canUploadNow] — rechecked every 5 s to avoid a
  /// slow async connectivity check on every 250 ms tick.
  UploadGateResult _cachedGate = const UploadGateResult.allowed();
  DateTime _gateCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _gateCheckInterval = Duration(seconds: 5);

  /// Timer used to debounce [_saveQueue] calls so we don't hammer Hive
  /// with a write on every progress event (which can be dozens per second).
  Timer? _saveDebounce;

  /// Throttles Riverpod state updates during high-frequency upload progress events
  /// to prevent UI freezes.
  final Map<String, DateTime> _lastProgressUpdate = {};

  /// Snapshot of total uploaded bytes across all jobs as of the last tick,
  /// used only to derive a real bytes/sec speed reading for display.
  int _lastTickTotalUploadedBytes = 0;

  /// Task 19.12 — offline-upload queueing.
  ///
  /// Runs independently of [_ticker] (which only exists while something is
  /// actively queued/uploading) so a job that failed because the device
  /// was offline keeps getting retried in the background even if the user
  /// never reopens the upload screen. Backoff intervals below are indexed
  /// by [UploadJobModel.offlineRetryCount] (clamped to the last entry) so
  /// a genuinely offline device isn't hammered with requests every few
  /// seconds.
  static const List<int> _offlineBackoffSeconds = [2, 5, 10, 20, 30];

  Timer? _offlineRetryTicker;

  // Simulated cellular flag to check WiFi-only option
  bool _simulateCellular = false;
  bool get simulateCellular => _simulateCellular;

  Future<void> scopeToUser(String userId) async {
    await _localStore.scopeToUser(userId);
    // Reload jobs from the newly-scoped store
    final jobs = await _localStore.load();
    final current = state.value;
    if (current != null) {
      state = AsyncValue.data(current.copyWith(jobs: jobs));
    }
  }

  Future<void> clearForLogout() async {
    await _localStore.clearForLogout();
    final current = state.value;
    if (current != null) {
      state = AsyncValue.data(current.copyWith(jobs: []));
    }
  }

  @override
  FutureOr<UploadQueueState> build() async {
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
      _offlineRetryTicker?.cancel();
      _offlineRetryTicker = null;
      _saveDebounce?.cancel();
      _saveDebounce = null;
      for (final token in _uploadCancelTokens.values) {
        token.cancel('Upload queue disposed');
      }
      _uploadCancelTokens.clear();
    });

    ref.listen<AuthState>(authStateProvider, (previous, next) {
      final userId = next.user?.id;
      if (userId != null) {
        // ignore: unawaited_futures
        scopeToUser(userId);
      } else if (previous?.user != null) {
        // ignore: unawaited_futures
        clearForLogout();
      }
    }, fireImmediately: true);

    // Task 19.12: poll for jobs that failed because the device looked
    // offline and requeue them once their backoff window has passed —
    // this runs for the controller's whole lifetime, not just while the
    // wizard's Progress step is open, since a job can go offline-pending
    // long after the user has left that screen.
    _offlineRetryTicker ??= Timer.periodic(
        const Duration(seconds: 5), (_) => _tickOfflineRetries());

    // Load from Hive database
    final persistedJobs = await _localStore.load();

    // Sanitize any stuck jobs from a previous launch
    final sanitizedJobs = persistedJobs.map((j) {
      if (j.status == UploadJobStatus.uploading) {
        return j.copyWith(status: UploadJobStatus.paused);
      }
      return j;
    }).toList();

    // If there are unfinished jobs, we start in step 2 (Progress) so user can see them
    final hasUnfinished = sanitizedJobs.any((j) => !j.isDone);

    return UploadQueueState(
      jobs: sanitizedJobs,
      isProcessing: false,
      wizardStep: hasUnfinished ? 2 : 0,
    );
  }

  void toggleSimulationNetwork() {
    _simulateCellular = !_simulateCellular;
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(
      message: _simulateCellular
          ? "Simulating: Cellular Data active"
          : "Simulating: Wi-Fi active",
    ));
    // If ticker is active, it will automatically pause wifi-only jobs next tick
    if (_ticker == null && !_simulateCellular) {
      _ensureProcessing();
    }
  }

  Future<void> _refreshMediaGrid(MediaModel media) async {
    try {
      final controller = ref.read(mediaProvider);
      controller.insertMediaLocally(media);
    } catch (_) {
      // ignore if provider not fully setup in test
    }
    // Also refresh albumProvider so that photoCount / folderCount shown in
    // the Album Details header ("X photos • Y folders") reflect the newly
    // uploaded media immediately.
    // Use refreshSilently() so the album list does NOT flash a loading
    // spinner or rebuild the whole screen — existing data stays visible
    // while the network fetch happens in the background.
    try {
      await ref.read(albumProvider).refreshSilently();
    } catch (_) {
      // albumProvider not ready (e.g. isolated tests) — safe to ignore.
    }
    try {
      ref.read(adminDashboardProvider.notifier).refresh();
    } catch (_) {}
  }

  // Wizard transitions
  void setWizardStep(int step) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(wizardStep: step));
  }

  void updatePickedFiles(List<PickedFileInfo> files) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(tempPickedFiles: files));
  }

  void removePickedFileAt(int index) {
    final current = state.value;
    if (current == null) return;
    final files = [...current.tempPickedFiles];
    files.removeAt(index);
    state = AsyncValue.data(current.copyWith(tempPickedFiles: files));
  }

  void clearPickedFiles() {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(
      tempPickedFiles: const [],
      wizardStep: 0,
      clearAlbum: true,
      clearFolder: true,
      clearRenamePrefix: true,
    ));
  }

  void updateOptions({
    String? albumId,
    bool clearAlbum = false,
    String? folderId,
    bool clearFolder = false,
    String? renamePrefix,
    bool clearRenamePrefix = false,
    bool? compress,
    bool? wifiOnly,
    bool? keepOriginalQuality,
    bool? uploadMetadata,
  }) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(
      selectedAlbumId: clearAlbum ? null : (albumId ?? current.selectedAlbumId),
      selectedFolderId:
          clearFolder ? null : (folderId ?? current.selectedFolderId),
      renamePrefix:
          clearRenamePrefix ? null : (renamePrefix ?? current.renamePrefix),
      compress: compress ?? current.compress,
      wifiOnly: wifiOnly ?? current.wifiOnly,
      keepOriginalQuality: keepOriginalQuality ?? current.keepOriginalQuality,
      uploadMetadata: uploadMetadata ?? current.uploadMetadata,
    ));
  }

  Future<void> _saveQueue() async {
    final current = state.value;
    if (current == null) return;
    await _localStore.saveAll(current.jobs);
  }

  /// Debounced version of [_saveQueue] — coalesces rapid successive calls
  /// (e.g. from progress events firing dozens of times per second) into
  /// a single write 500 ms after the last call.
  void _debouncedSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _saveQueue);
  }

  /// Add picked files to the persistent queue and start the uploading process
  Future<void> startUpload() async {
    final current = state.value;
    if (current == null || current.tempPickedFiles.isEmpty) return;

    final List<UploadJobModel> newJobs = [];
    final prefix = current.renamePrefix?.trim() ?? '';

    for (int i = 0; i < current.tempPickedFiles.length; i++) {
      final f = current.tempPickedFiles[i];
      final originalName = f.name.isNotEmpty ? f.name : 'untitled_${i + 1}';

      // Rename handling
      String finalName = originalName;
      if (prefix.isNotEmpty) {
        final dotIdx = originalName.lastIndexOf('.');
        final ext = (dotIdx != -1) ? originalName.substring(dotIdx) : '';
        finalName = current.tempPickedFiles.length == 1
            ? '$prefix$ext'
            : '$prefix (${i + 1})$ext';
      }

      // `f.path` isn't just null on web — touching the getter itself
      // throws — so it has to stay behind a `kIsWeb` check rather than
      // a `?? ''`. Web instead carries its bytes through [webBytes] for
      // small files, or [webStreamFactory] for large files (>10 MB).
      newJobs.add(UploadJobModel(
        id: '${DateTime.now().microsecondsSinceEpoch}_$i',
        fileName: finalName,
        filePath: kIsWeb ? '' : (f.path ?? ''),
        webBytes: kIsWeb ? f.bytes : null,
        webStreamFactory: kIsWeb ? f.streamFactory : null,
        webBlobUrl: kIsWeb ? f.webBlobUrl : null,
        albumId: current.selectedAlbumId,
        folderId: current.selectedFolderId,
        totalBytes:
            f.sizeBytes > 0 ? f.sizeBytes : 1024 * 1024 * 5, // Default to 5MB
        uploadedBytes: 0,
        createdAt: DateTime.now(),
        status: UploadJobStatus.queued,
        compress: current.compress,
        wifiOnly: current.wifiOnly,
        keepOriginalQuality: current.keepOriginalQuality,
        uploadMetadata: current.uploadMetadata,
      ));
    }

    state = AsyncValue.data(current.copyWith(
      jobs: [...current.jobs, ...newJobs],
      tempPickedFiles: const [],
      wizardStep: 2, // Navigates to Progress view
      message: 'Uploading ${newJobs.length} item(s)',
    ));

    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> enqueueFiles({
    required List<PickedFileInfo> files,
    String? albumId,
    String? folderId,
    String? renamePrefix,
    bool compress = false,
    bool wifiOnly = false,
    bool keepOriginalQuality = true,
    bool? uploadMetadata,
  }) async {
    updatePickedFiles(files);
    updateOptions(
      albumId: albumId,
      folderId: folderId,
      renamePrefix: renamePrefix,
      compress: compress,
      wifiOnly: wifiOnly,
      keepOriginalQuality: keepOriginalQuality,
      uploadMetadata: uploadMetadata,
    );
    await startUpload();
  }

  void _ensureProcessing() {
    if (state.value?.isProcessing == true) return;

    final current = state.value;
    if (current == null) return;
    if (current.jobs
        .every((j) => j.isDone || j.status == UploadJobStatus.paused)) {
      return;
    }

    state = AsyncValue.data(
      current.copyWith(isProcessing: true, clearMessage: true),
    );
    unawaited(_startForegroundService(current));

    _ticker?.cancel();

    _lastTickTotalUploadedBytes =
        current.jobs.fold<int>(0, (sum, j) => sum + j.uploadedBytes);

    // Ticks every 250ms — its job is to:
    //  (a) fill up to [_maxConcurrentUploads] upload slots with queued jobs,
    //  (b) derive a speed/ETA reading from bytes moved since the last tick.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      final s = state.value;
      if (s == null) return;

      final now = DateTime.now();
      final needsGateRefresh =
          now.difference(_gateCheckedAt) >= _gateCheckInterval;
      if (needsGateRefresh) {
        _cachedGate = await canUploadNow(ref);
        _gateCheckedAt = now;
      }
      final gate = _cachedGate;

      // The per-batch "Upload using WiFi only" option (`job.wifiOnly`,
      // set on the upload wizard's options step) is a separate opt-in
      // from the global Settings toggle above, and needs its own real
      // connectivity check (also cached here).
      final anyJobWantsWifiOnly = s.jobs.any((j) =>
          j.wifiOnly &&
          (j.status == UploadJobStatus.uploading ||
              j.status == UploadJobStatus.queued));
      final realOnWifi =
          (anyJobWantsWifiOnly && !_simulateCellular && needsGateRefresh)
              ? await ref.read(networkConnectivityServiceProvider).isOnWifi()
              : true;

      final inFlightCount = _inFlightJobIds.length;
      final slotsAvailable = _maxConcurrentUploads - inFlightCount;
      final hasQueued = s.jobs.any((j) => j.status == UploadJobStatus.queued);

      // Fill all available concurrency slots with queued jobs.
      if (slotsAvailable > 0 && hasQueued) {
        // Collect all queued jobs (up to the number of open slots).
        final queuedJobs = s.jobs
            .where((j) =>
                j.status == UploadJobStatus.queued &&
                !_inFlightJobIds.contains(j.id))
            .take(slotsAvailable)
            .toList();

        for (final job in queuedJobs) {
          final blockedBySimulation = job.wifiOnly && _simulateCellular;
          final blockedByRealGate = !gate.canUpload;
          final blockedByJobWifiOnly =
              job.wifiOnly && !_simulateCellular && !realOnWifi;

          if (blockedBySimulation ||
              blockedByRealGate ||
              blockedByJobWifiOnly) {
            // Pause this job — it can't upload right now.
            final idx = s.jobs.indexWhere((j) => j.id == job.id);
            if (idx != -1) {
              final updatedJobs = [...s.jobs];
              updatedJobs[idx] = job.copyWith(
                status: UploadJobStatus.paused,
                errorMessage: (blockedBySimulation || blockedByJobWifiOnly)
                    ? "Paused: WiFi required (on Cellular Network)"
                    : (gate.reason ?? "Waiting for Wi-Fi to upload"),
              );
              state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
              _debouncedSave();
            }
          } else {
            // Fire-and-forget: runs the real file read + network request,
            // updates state itself via onSendProgress as it goes.
            unawaited(_beginRealUpload(job));
          }
        }
      }

      // Cellular network check mid-upload — same caveat as pause/cancel:
      // this can't abort bytes already handed to `package:http`, only
      // update what the UI shows for a job that hasn't finished yet.
      final jobWifiOnlyBlocked = !_simulateCellular && !realOnWifi;
      if (_simulateCellular || !gate.canUpload || jobWifiOnlyBlocked) {
        final blocked = s.jobs.where((j) =>
            j.status == UploadJobStatus.uploading &&
            (j.wifiOnly && (_simulateCellular || jobWifiOnlyBlocked) ||
                !gate.canUpload));
        if (blocked.isNotEmpty) {
          final updatedJobs = s.jobs.map((j) {
            if (j.status == UploadJobStatus.uploading &&
                (j.wifiOnly && (_simulateCellular || jobWifiOnlyBlocked) ||
                    !gate.canUpload)) {
              return j.copyWith(
                status: UploadJobStatus.paused,
                errorMessage: (!gate.canUpload && (gate.reason != null))
                    ? gate.reason!
                    : "Paused: WiFi required (on Cellular Network)",
              );
            }
            return j;
          }).toList();
          state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
          _debouncedSave();
        }
      }

      // Derive a real bytes/sec reading from how far uploadedBytes moved
      // across all jobs since the last tick (tick = 250ms, so *4 for /sec).
      final refreshed = state.value ?? s;
      final totalUploadedNow =
          refreshed.jobs.fold<int>(0, (sum, j) => sum + j.uploadedBytes);
      final stillActive = refreshed.jobs.any((j) =>
          j.status == UploadJobStatus.uploading ||
          j.status == UploadJobStatus.queued);
      final deltaBytes = totalUploadedNow - _lastTickTotalUploadedBytes;
      _lastTickTotalUploadedBytes = totalUploadedNow;
      final currentSpeed =
          stillActive && deltaBytes > 0 ? (deltaBytes * 4).toDouble() : 0.0;

      unawaited(_updateForegroundService(refreshed, stillActive));

      Duration? estRemaining;
      if (currentSpeed > 0) {
        int remainingBytes = 0;
        for (final j in refreshed.jobs) {
          if (j.status == UploadJobStatus.uploading ||
              j.status == UploadJobStatus.queued) {
            remainingBytes += (j.totalBytes - j.uploadedBytes);
          }
        }
        if (remainingBytes > 0) {
          final seconds = remainingBytes / currentSpeed;
          estRemaining = Duration(seconds: seconds.ceil());
        }
      }

      state = AsyncValue.data(refreshed.copyWith(
        isProcessing: stillActive,
        speedBytesPerSecond: stillActive ? currentSpeed : 0.0,
        remainingTime: stillActive ? estRemaining : null,
        clearRemainingTime: !stillActive,
      ));

      if (!stillActive) {
        _ticker?.cancel();
        _ticker = null;
        unawaited(UploadForegroundService.stop());
      }
    });
  }

  Future<void> _startForegroundService(UploadQueueState queue) async {
    final activeCount = queue.jobs
        .where((job) =>
            job.status == UploadJobStatus.queued ||
            job.status == UploadJobStatus.uploading)
        .length;
    if (activeCount == 0) return;
    try {
      await UploadForegroundService.start(activeCount: activeCount);
    } catch (error, stackTrace) {
      debugPrint(
          'Could not start upload foreground service: $error\n$stackTrace');
    }
  }

  Future<void> _updateForegroundService(
      UploadQueueState queue, bool stillActive) async {
    if (!stillActive) return;
    final activeCount = queue.jobs
        .where((job) =>
            job.status == UploadJobStatus.queued ||
            job.status == UploadJobStatus.uploading)
        .length;
    if (activeCount == 0) return;
    final totalBytes =
        queue.jobs.fold<int>(0, (sum, job) => sum + job.totalBytes);
    final uploadedBytes =
        queue.jobs.fold<int>(0, (sum, job) => sum + job.uploadedBytes);
    final percentDone = totalBytes == 0
        ? 0
        : (((uploadedBytes * 100) ~/ totalBytes).clamp(0, 100)).toInt();
    try {
      await UploadForegroundService.update(
        activeCount: activeCount,
        percentDone: percentDone.clamp(0, 100),
      );
    } catch (error, stackTrace) {
      debugPrint(
          'Could not update upload foreground service: $error\n$stackTrace');
    }
  }

  /// Starts the real upload for [job]: reads its bytes off disk and sends
  /// them to the API-backed repository, wiring [MediaRepository.uploadMedia]'s
  /// `onSendProgress(sent, total)` straight onto that job's
  /// `uploadedBytes`/`totalBytes` (Task 19.11) so [UploadQueueTile]'s
  /// progress bar reflects bytes actually on the wire — not a guess.
  Future<void> _beginRealUpload(UploadJobModel job) async {
    _inFlightJobIds.add(job.id);
    final cancelToken = CancelToken();
    _uploadCancelTokens[job.id] = cancelToken;

    final started = state.value;
    if (started == null) {
      _inFlightJobIds.remove(job.id);
      return;
    }
    final startedJobs = started.jobs.map((j) {
      if (j.id != job.id) return j;
      return j.copyWith(
        status: UploadJobStatus.uploading,
        startedAt: DateTime.now(),
        clearError: true,
      );
    }).toList();
    state = AsyncValue.data(started.copyWith(jobs: startedJobs));
    _debouncedSave(); // non-blocking — don't delay the actual upload

    try {
      final contentType = MediaContentType.forFileName(job.fileName);

      // Compression is permanently disabled — files are always uploaded at
      // their original quality regardless of per-job options or global
      // upload quality settings. This ensures photos and videos are never
      // degraded during upload.
      List<int>? finalBytes;
      String? finalFilePath;

      if (kIsWeb) {
        if (job.webStreamFactory != null) {
          // Large web file: stream directly to avoid OOM.
        } else if (job.webBytes == null) {
          throw StateError('No bytes available for this file');
        } else {
          finalBytes = job.webBytes;
        }
      } else {
        finalFilePath = job.filePath;
      }

      // On native platforms, if there's no filePath and no bytes, the file
      // cannot be sent — surface a clear message rather than crashing.
      if (!kIsWeb && finalFilePath != null && finalFilePath.isEmpty) {
        throw StateError('File path is empty — this file cannot be uploaded.');
      }

      final media = await _mediaRepo.uploadMedia(
        bytes: finalBytes,
        filePath: finalFilePath,
        // Stream<Uint8List> is not assignable to Stream<List<int>> directly
        // in Dart due to invariant generics, so cast via .cast<List<int>>().
        streamData: kIsWeb && job.webStreamFactory != null
            ? () => job.webStreamFactory!().cast<List<int>>()
            : null,
        webBlobUrl: job.webBlobUrl,
        fileName: job.fileName,
        contentType: contentType,
        sizeBytes: job.totalBytes,
        albumId: job.albumId,
        folderId: job.folderId,
        existingUploadId: job.uploadId,
        existingMediaId: job.uploadMediaId,
        completedParts: job.completedParts,
        onUploadStarted: (uploadId, mediaId) {
          final current = state.value;
          if (current == null) return;
          final index = current.jobs.indexWhere((item) => item.id == job.id);
          if (index < 0) return;
          final jobs = [...current.jobs];
          jobs[index] = jobs[index].copyWith(
            uploadId: uploadId,
            uploadMediaId: mediaId,
          );
          state = AsyncValue.data(current.copyWith(jobs: jobs));
          _debouncedSave();
        },
        onPartUploaded: (partNumber, etag) {
          final current = state.value;
          if (current == null) return;
          final index = current.jobs.indexWhere((item) => item.id == job.id);
          if (index < 0) return;
          final currentJob = current.jobs[index];
          final completed = {...currentJob.completedParts};
          completed[partNumber.toString()] = etag;
          final jobs = [...current.jobs];
          jobs[index] = currentJob.copyWith(completedParts: completed);
          state = AsyncValue.data(current.copyWith(jobs: jobs));
          _debouncedSave();
        },
        cancelToken: cancelToken,
        onSendProgress: (sent, total) => _onRealProgress(job.id, sent, total),
      );
      await _onRealSuccess(job.id, media);
    } on ApiException catch (e) {
      // statusCode 0 → never reached the server (DNS / connection refused / timeout).
      // 5xx or 429 → server-side transient error (overloaded / rate-limited).
      // Both are worth auto-retrying with backoff.
      // Any other 4xx (400/401/413/etc.) is a real rejection that retrying
      // blindly won't fix — keep those as manual-retry failures.
      final isRetriable = e.statusCode == 0 ||
          e.statusCode == 429 ||
          (e.statusCode >= 500 && e.statusCode < 600);
      await _onRealFailure(job.id, e.message, isConnectivityIssue: isRetriable);
    } catch (e) {
      debugPrint('Upload failed for ${job.fileName}: $e');
      await _onRealFailure(
          job.id, 'Upload could not be completed: ${e.toString()}');
    } finally {
      _inFlightJobIds.remove(job.id);
      if (identical(_uploadCancelTokens[job.id], cancelToken)) {
        _uploadCancelTokens.remove(job.id);
      }
    }
  }

  /// Called by the real `onSendProgress` callback, potentially many times
  /// a second, while [jobId]'s upload is on the wire.
  void _onRealProgress(String jobId, int sent, int total) {
    final s = state.value;
    if (s == null) return;
    final idx = s.jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;

    final job = s.jobs[idx];
    // The user paused/canceled this job's *UI* state, but package:http
    // has no cancellation token, so the request already in flight can't
    // actually be aborted. Stop reflecting its progress once it's no
    // longer "uploading" so the tile doesn't fight the state the user
    // asked for; _onRealSuccess/_onRealFailure below still reconcile
    // once the request actually finishes.
    if (job.status != UploadJobStatus.uploading) return;

    final resolvedTotal = total > 0 ? total : job.totalBytes;
    final cappedSent = sent > resolvedTotal ? resolvedTotal : sent;
    final isComplete = cappedSent >= resolvedTotal;

    final now = DateTime.now();
    final lastUpdate = _lastProgressUpdate[jobId];
    if (!isComplete &&
        lastUpdate != null &&
        now.difference(lastUpdate).inMilliseconds < 150) {
      return; // Throttle UI updates to prevent freezing on large files
    }
    _lastProgressUpdate[jobId] = now;

    final updatedJobs = [...s.jobs];
    updatedJobs[idx] = job.copyWith(
      uploadedBytes: cappedSent,
      totalBytes: resolvedTotal,
    );
    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
  }

  Future<void> _onRealSuccess(String jobId, MediaModel media) async {
    final s = state.value;
    if (s == null) return;
    final idx = s.jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;

    final job = s.jobs[idx];
    // A cancel can't retract bytes that already reached the server, but
    // it can at least keep the local queue honoring the user's intent
    // instead of flipping a canceled row back to "completed".
    if (job.status == UploadJobStatus.canceled ||
        job.status == UploadJobStatus.paused) {
      return;
    }

    final updatedJobs = [...s.jobs];
    updatedJobs[idx] = job.copyWith(
      status: UploadJobStatus.completed,
      uploadedBytes: job.totalBytes,
      finishedAt: DateTime.now(),
      clearError: true,
    );

    final stillActive = updatedJobs.any((j) =>
        j.status == UploadJobStatus.uploading ||
        j.status == UploadJobStatus.queued);

    state = AsyncValue.data(s.copyWith(
      jobs: updatedJobs,
      // Auto go to the Success/Complete screen (step 3) once nothing is
      // left uploading or queued.
      wizardStep: (!stillActive && s.wizardStep == 2) ? 3 : s.wizardStep,
    ));
    _debouncedSave();

    // Immediately fill freed-up slot with the next queued job instead of
    // waiting up to 250 ms for the next ticker tick.
    if (stillActive) _ensureProcessing();

    // Auto-refresh the Gallery provider — a real row now exists
    // server-side for this job.
    await _refreshMediaGrid(media);
  }

  Future<void> _onRealFailure(String jobId, String message,
      {bool isConnectivityIssue = false}) async {
    final s = state.value;
    if (s == null) return;
    final idx = s.jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;

    final job = s.jobs[idx];
    if (job.status == UploadJobStatus.canceled ||
        job.status == UploadJobStatus.paused) {
      return;
    }

    final updatedJobs = [...s.jobs];
    if (isConnectivityIssue) {
      final backoffIdx = job.offlineRetryCount < _offlineBackoffSeconds.length
          ? job.offlineRetryCount
          : _offlineBackoffSeconds.length - 1;
      final backoff = _offlineBackoffSeconds[backoffIdx];
      // Distinguish "server side error" from "truly offline" to give the
      // user a more accurate message. Both use the same auto-retry path.
      final friendlyMsg = message.isNotEmpty &&
              !message.contains("Couldn't reach the server")
          ? 'Server error — retrying automatically...'
          : "No connection — will retry automatically once you're back online.";
      updatedJobs[idx] = job.copyWith(
        status: UploadJobStatus.failed,
        errorMessage: friendlyMsg,
        offlinePending: true,
        offlineRetryCount: job.offlineRetryCount + 1,
        nextRetryAt: DateTime.now().add(Duration(seconds: backoff)),
      );
    } else {
      // A real server-side rejection (bad content type, 413, 401, a
      // missing/unreadable file, etc.) — retrying blindly won't help, so
      // this stays a plain failure the user resolves with a manual Retry.
      updatedJobs[idx] = job.copyWith(
        status: UploadJobStatus.failed,
        errorMessage: message,
        offlinePending: false,
        offlineRetryCount: 0,
        clearNextRetryAt: true,
      );
    }
    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    _debouncedSave();
    // A slot just freed up — try to start the next queued job immediately.
    _ensureProcessing();
  }

  /// Task 19.12: requeues any job whose last failure looked like a
  /// connectivity problem and whose backoff window has passed. Requeuing
  /// just flips it back to `queued` and calls [_ensureProcessing] — the
  /// normal upload path (and [_beginRealUpload]'s real `onSendProgress`
  /// hookup from Task 19.11) takes it from there, same as if the user had
  /// tapped Retry by hand.
  Future<void> _tickOfflineRetries() async {
    final s = state.value;
    if (s == null) return;

    final now = DateTime.now();
    final dueJobIds = s.jobs
        .where((j) =>
            j.status == UploadJobStatus.failed &&
            j.offlinePending &&
            (j.nextRetryAt == null || !now.isBefore(j.nextRetryAt!)))
        .map((j) => j.id)
        .toSet();
    if (dueJobIds.isEmpty) return;

    final updatedJobs = s.jobs.map((j) {
      if (!dueJobIds.contains(j.id)) return j;
      return j.copyWith(
        status: UploadJobStatus.queued,
        clearError: true,
        clearNextRetryAt: true,
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> pauseJob(String jobId) async {
    final s = state.value;
    if (s == null) return;
    _uploadCancelTokens[jobId]?.cancel('Paused by user');

    final updatedJobs = s.jobs.map((j) {
      if (j.id != jobId) return j;
      if (j.isDone) return j;
      return j.copyWith(
        status: UploadJobStatus.paused,
        errorMessage: "Paused by user",
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();

    if (updatedJobs
        .every((j) => j.isDone || j.status == UploadJobStatus.paused)) {
      _stopTickerAndService();
      state = AsyncValue.data(s.copyWith(
        jobs: updatedJobs,
        isProcessing: false,
        speedBytesPerSecond: 0.0,
        remainingTime: null,
      ));
    }
  }

  Future<void> resumeJob(String jobId) async {
    final s = state.value;
    if (s == null) return;

    final updatedJobs = s.jobs.map((j) {
      if (j.id != jobId) return j;
      if (j.status != UploadJobStatus.paused) return j;
      return j.copyWith(
        status: UploadJobStatus.queued,
        clearError: true,
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> pauseAll() async {
    final s = state.value;
    if (s == null) return;
    for (final token in _uploadCancelTokens.values) {
      token.cancel('Paused by user');
    }

    final updatedJobs = s.jobs.map((j) {
      if (j.isDone) return j;
      return j.copyWith(
        status: UploadJobStatus.paused,
        errorMessage: "Paused by user",
      );
    }).toList();

    _stopTickerAndService();

    state = AsyncValue.data(s.copyWith(
      jobs: updatedJobs,
      isProcessing: false,
      speedBytesPerSecond: 0.0,
      remainingTime: null,
    ));
    await _saveQueue();
  }

  Future<void> resumeAll() async {
    final s = state.value;
    if (s == null) return;

    final updatedJobs = s.jobs.map((j) {
      if (j.status != UploadJobStatus.paused) return j;
      return j.copyWith(
        status: UploadJobStatus.queued,
        clearError: true,
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> cancelJob(String jobId) async {
    final s = state.value;
    if (s == null) return;
    _uploadCancelTokens[jobId]?.cancel('Canceled by user');

    final updatedJobs = s.jobs.map((j) {
      if (j.id != jobId) return j;
      if (j.isDone) return j;
      return j.copyWith(
        status: UploadJobStatus.canceled,
        finishedAt: DateTime.now(),
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(
      jobs: updatedJobs,
      message: 'Canceled upload',
    ));
    await _saveQueue();

    if (updatedJobs.every((j) => j.isDone)) {
      _stopTickerAndService();
      state = AsyncValue.data(state.value!.copyWith(
        isProcessing: false,
        speedBytesPerSecond: 0.0,
        remainingTime: null,
      ));
    }
  }

  Future<void> cancelAll() async {
    final s = state.value;
    if (s == null) return;
    for (final token in _uploadCancelTokens.values) {
      token.cancel('Canceled by user');
    }

    final updatedJobs = s.jobs.map((j) {
      if (j.isDone) return j;
      return j.copyWith(
        status: UploadJobStatus.canceled,
        finishedAt: DateTime.now(),
      );
    }).toList();

    _stopTickerAndService();

    state = AsyncValue.data(s.copyWith(
      jobs: updatedJobs,
      isProcessing: false,
      speedBytesPerSecond: 0.0,
      remainingTime: null,
      message: 'Canceled all uploads',
    ));
    await _saveQueue();
  }

  /// Stops the progress ticker AND the foreground-service notification.
  /// The ticker only stops the service itself when it notices that nothing
  /// is active; every path that cancels the ticker directly (pause / cancel
  /// / remove) must stop the service too, or the "Uploading N files"
  /// notification stays up with nothing running behind it.
  void _stopTickerAndService() {
    _ticker?.cancel();
    _ticker = null;
    unawaited(UploadForegroundService.stop());
  }

  /// Removes [jobId] from the queue list (swipe-to-delete).
  ///
  /// A job that is still queued / uploading / paused is canceled first (its
  /// in-flight request is aborted through the cancel token), so nothing
  /// keeps uploading in the background after its row is gone. A finished
  /// job (completed / failed / canceled) is simply dropped from the list —
  /// media that already reached the server is NOT deleted.
  ///
  /// The list is updated synchronously (before the first `await`) because a
  /// `Dismissible` must leave the widget tree in the same frame it is
  /// dismissed.
  Future<void> removeJob(String jobId) async {
    final s = state.value;
    if (s == null) return;
    final idx = s.jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;
    final job = s.jobs[idx];

    if (!job.isDone) _uploadCancelTokens[jobId]?.cancel('Removed by user');
    _lastProgressUpdate.remove(jobId);

    final remaining = [...s.jobs]..removeAt(idx);
    final stillActive = remaining.any((j) =>
        j.status == UploadJobStatus.uploading ||
        j.status == UploadJobStatus.queued);

    state = AsyncValue.data(s.copyWith(
      jobs: remaining,
      isProcessing: s.isProcessing && stillActive,
      speedBytesPerSecond: stillActive ? s.speedBytesPerSecond : 0.0,
      clearRemainingTime: !stillActive,
    ));
    if (!stillActive) _stopTickerAndService();

    await _saveQueue();
  }

  /// "Undo" for [removeJob]: puts a finished job back in its original
  /// (creation-time) position. No-op for active jobs — a canceled network
  /// request can't be resumed by re-inserting its row.
  Future<void> restoreJob(UploadJobModel job) async {
    final s = state.value;
    if (s == null) return;
    if (!job.isDone || s.jobs.any((j) => j.id == job.id)) return;

    final jobs = [...s.jobs, job]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    state = AsyncValue.data(s.copyWith(jobs: jobs));
    await _saveQueue();
  }

  /// Manual retry for a single job — this is what the per-tile Retry
  /// button calls (Task 19.12 also fixes that button: it previously
  /// called `resumeJob`, which only acts on `paused` jobs and so silently
  /// did nothing for a `failed` one).
  Future<void> retryJob(String jobId) async {
    final s = state.value;
    if (s == null) return;

    final updatedJobs = s.jobs.map((j) {
      if (j.id != jobId || j.status != UploadJobStatus.failed) return j;
      return j.copyWith(
        status: UploadJobStatus.queued,
        uploadedBytes: 0,
        clearUploadSession: true,
        clearError: true,
        offlinePending: false,
        offlineRetryCount: 0,
        clearNextRetryAt: true,
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> retryFailed() async {
    final s = state.value;
    if (s == null) return;

    final updatedJobs = s.jobs.map((j) {
      if (j.status != UploadJobStatus.failed) return j;
      return j.copyWith(
        status: UploadJobStatus.queued,
        uploadedBytes: 0,
        clearUploadSession: true,
        clearError: true,
        offlinePending: false,
        offlineRetryCount: 0,
        clearNextRetryAt: true,
      );
    }).toList();

    state = AsyncValue.data(s.copyWith(jobs: updatedJobs));
    await _saveQueue();
    _ensureProcessing();
  }

  Future<void> clearCompleted() async {
    final s = state.value;
    if (s == null) return;

    final remainingJobs = s.jobs.where((j) => !j.isDone).toList();
    state = AsyncValue.data(s.copyWith(jobs: remainingJobs));
    await _saveQueue();
  }

  Future<void> resetWizard() async {
    final s = state.value;
    if (s == null) return;

    state = AsyncValue.data(s.copyWith(
      wizardStep: 0,
      tempPickedFiles: const [],
      clearAlbum: true,
      clearFolder: true,
      clearRenamePrefix: true,
    ));
  }

  Future<void> failFirstNonDone() async {
    final s = state.value;
    if (s == null) return;

    final idx = s.jobs.indexWhere((j) => !j.isDone);
    if (idx == -1) return;

    final updated = [...s.jobs];
    final j = updated[idx];
    updated[idx] = j.copyWith(
      status: UploadJobStatus.failed,
      finishedAt: DateTime.now(),
      errorMessage: 'Simulated connection failure',
    );

    state = AsyncValue.data(s.copyWith(
      jobs: updated,
      message: 'Upload failed (simulated)',
    ));
    await _saveQueue();

    if (updated.every((j) => j.isDone)) {
      _ticker?.cancel();
      _ticker = null;
      state = AsyncValue.data(state.value!.copyWith(
        isProcessing: false,
        speedBytesPerSecond: 0.0,
        remainingTime: null,
      ));
    }
  }
}

final uploadQueueProvider =
    AsyncNotifierProvider<UploadQueueController, UploadQueueState>(
  () => UploadQueueController(),
);
