import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routes/app_routes.dart';
import '../core/theme/app_theme.dart';
import 'upload_queue_provider.dart';
import 'upload_job_model.dart';
import 'widgets/dismissible_upload_tile.dart';
import 'widgets/upload_queue_tile.dart';

class UploadHubScreen extends ConsumerWidget {
  const UploadHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(uploadQueueProvider);
    final notifier = ref.read(uploadQueueProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (state.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final data = state.value;
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Uploads')),
        body: const Center(child: Text('Failed to load uploads')),
      );
    }

    final activeJobs = data.jobs
        .where((j) =>
            j.status == UploadJobStatus.uploading ||
            j.status == UploadJobStatus.queued ||
            j.status == UploadJobStatus.paused)
        .toList();
    final failedJobs = data.jobs
        .where((j) =>
            j.status == UploadJobStatus.failed ||
            j.status == UploadJobStatus.canceled)
        .toList();
    final completedJobs =
        data.jobs.where((j) => j.status == UploadJobStatus.completed).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Uploads'),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pushNamed(AppRoutes.newUpload);
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('New upload'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Banner for overall progress
          if (activeJobs.isNotEmpty)
            _buildOverallBanner(context, data, notifier, isDark),
          // List of sections
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                if (activeJobs.isNotEmpty)
                  _buildSectionHeader('Active', isDark),
                ...activeJobs.map((job) => DismissibleUploadTile(
                      job: job,
                      onRemove: () => notifier.removeJob(job.id),
                      onRestore: () => notifier.restoreJob(job),
                      child: UploadQueueTile(
                      job: job,
                      speedBytesPerSecond: data.speedBytesPerSecond,
                      remainingTime: data.remainingTime,
                      onCancel: () => notifier.cancelJob(job.id),
                      onPause: () => notifier.pauseJob(job.id),
                      onResume: () => notifier.resumeJob(job.id),
                      onRetry: () => notifier.retryJob(job.id),
                    ),
                    )),
                if (failedJobs.isNotEmpty)
                  _buildSectionHeader('Failed or Canceled', isDark),
                ...failedJobs.map((job) => DismissibleUploadTile(
                      job: job,
                      onRemove: () => notifier.removeJob(job.id),
                      onRestore: () => notifier.restoreJob(job),
                      child: UploadQueueTile(
                      job: job,
                      onCancel: () => notifier.cancelJob(job.id),
                      onPause: () => notifier.pauseJob(job.id),
                      onResume: () => notifier.resumeJob(job.id),
                      onRetry: () => notifier.retryJob(job.id),
                    ),
                    )),
                if (completedJobs.isNotEmpty)
                  _buildSectionHeader('Completed', isDark),
                ...completedJobs.map((job) => DismissibleUploadTile(
                      job: job,
                      onRemove: () => notifier.removeJob(job.id),
                      onRestore: () => notifier.restoreJob(job),
                      child: UploadQueueTile(
                      job: job,
                      onCancel: () => notifier.cancelJob(job.id),
                      onPause: () => notifier.pauseJob(job.id),
                      onResume: () => notifier.resumeJob(job.id),
                      onRetry: () => notifier.retryJob(job.id),
                    ),
                    )),
                if (data.jobs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 100),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_done_rounded,
                              size: 64, color: Colors.grey.shade400),
                          const SizedBox(height: 16),
                          const Text(
                            'No uploads in queue',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey),
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: () {
                              Navigator.of(context)
                                  .pushNamed(AppRoutes.newUpload);
                            },
                            icon: const Icon(Icons.upload_file_rounded),
                            label: const Text('Start an upload'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: isDark ? AppColors.textOnDark : AppColors.text,
        ),
      ),
    );
  }

  Widget _buildOverallBanner(
      BuildContext context, dynamic data, dynamic notifier, bool isDark) {
    // Ported from _buildProgressStep
    final completedCount = data.completedCount;
    final totalCount = data.jobs.length;

    String formattedSpeed = '0 KB/s';
    if (data.speedBytesPerSecond > 0) {
      if (data.speedBytesPerSecond >= 1024 * 1024) {
        formattedSpeed =
            '${(data.speedBytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
      } else {
        formattedSpeed =
            '${(data.speedBytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
      }
    }

    String formattedTime = 'estimating...';
    if (data.remainingTime != null) {
      final t = data.remainingTime!;
      if (t.inMinutes > 0) {
        formattedTime = '${t.inMinutes}m ${t.inSeconds % 60}s remaining';
      } else {
        formattedTime = '${t.inSeconds}s remaining';
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : Colors.white,
        border: Border(
            bottom: BorderSide(
                color: isDark ? AppColors.darkBorder : Colors.grey.shade100)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                data.isProcessing
                    ? 'Uploading Studio Media...'
                    : 'Upload Process Paused',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: data.isProcessing
                      ? AppColors.primary
                      : Colors.orange.shade800,
                ),
              ),
              Text(
                '$completedCount of $totalCount done',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.subtitleOnDark : Colors.black54,
                    fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: data.overallProgress,
              minHeight: 8,
              backgroundColor:
                  isDark ? AppColors.darkSurfaceRaised : Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(
                data.isProcessing ? AppColors.primary : Colors.orange.shade700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded,
                      size: 14,
                      color:
                          isDark ? AppColors.subtitleOnDark : Colors.black45),
                  const SizedBox(width: 4),
                  Text(
                    formattedSpeed,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? AppColors.subtitleOnDark : Colors.black54),
                  ),
                ],
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined,
                      size: 14,
                      color:
                          isDark ? AppColors.subtitleOnDark : Colors.black45),
                  const SizedBox(width: 4),
                  Text(
                    data.isProcessing ? formattedTime : 'Paused',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? AppColors.subtitleOnDark : Colors.black54),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (data.isProcessing)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: notifier.pauseAll,
                    icon: const Icon(Icons.pause_rounded, size: 16),
                    label: const Text('Pause All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                )
              else if (data.jobs.any((j) => j.status == UploadJobStatus.paused))
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: notifier.resumeAll,
                    icon: const Icon(Icons.play_arrow_rounded, size: 16),
                    label: const Text('Resume All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: notifier.cancelAll,
                  icon: const Icon(Icons.cancel_rounded, size: 16),
                  label: const Text('Cancel All'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey.shade800,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
