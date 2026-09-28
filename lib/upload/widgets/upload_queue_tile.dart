import 'package:flutter/material.dart';
import '../upload_job_model.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// A premium, highly detailed list tile for an upload job in the queue.
///
/// Features:
/// - Distinct color schemes for each state (Queued, Uploading, Paused, Completed, Failed, Canceled)
/// - Format helper for bytes to KB/MB
/// - Visual badges for file types (Image/Video/File)
/// - Linear progress indicator with state color coding
/// - Contextual action buttons: Pause, Resume, Cancel, Retry
class UploadQueueTile extends StatelessWidget {
  final UploadJobModel job;
  final VoidCallback onCancel;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRetry;
  final double speedBytesPerSecond;
  final Duration? remainingTime;

  const UploadQueueTile({
    super.key,
    required this.job,
    required this.onCancel,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.speedBytesPerSecond = 0,
    this.remainingTime,
  });

  String _extensionLower() {
    final idx = job.fileName.lastIndexOf('.');
    if (idx == -1 || idx == job.fileName.length - 1) return '';
    return job.fileName.substring(idx + 1).toLowerCase();
  }

  bool get _isVideo {
    const videoExt = <String>{'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'};
    return videoExt.contains(_extensionLower());
  }

  bool get _isImage {
    const imageExt = <String>{'jpg', 'jpeg', 'png', 'webp', 'heic'};
    return imageExt.contains(_extensionLower());
  }

  String _humanBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }

    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  String _formatSpeed() {
    if (speedBytesPerSecond <= 0) return 'estimating speed';
    if (speedBytesPerSecond >= 1024 * 1024) {
      return '${(speedBytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${(speedBytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }

  String _formatRemaining() {
    if (remainingTime == null) return 'estimating time';
    final seconds = remainingTime!.inSeconds;
    if (seconds >= 3600) {
      return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m left';
    }
    if (seconds >= 60) return '${seconds ~/ 60}m ${seconds % 60}s left';
    return '$seconds s left';
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (job.status) {
      UploadJobStatus.queued => context.textMuted,
      UploadJobStatus.uploading => AppColors.primary,
      UploadJobStatus.paused => Colors.orange.shade700,
      UploadJobStatus.completed => AppColors.success,
      UploadJobStatus.failed => AppColors.error,
      UploadJobStatus.canceled => Colors.grey.shade600,
    };

    final statusBg = switch (job.status) {
      UploadJobStatus.queued => context.textMuted.withValues(alpha: 0.08),
      UploadJobStatus.uploading => AppColors.primary.withValues(alpha: 0.2),
      UploadJobStatus.paused => Colors.orange.withValues(alpha: 0.2),
      UploadJobStatus.completed => AppColors.success.withValues(alpha: 0.2),
      UploadJobStatus.failed => AppColors.error.withValues(alpha: 0.2),
      UploadJobStatus.canceled => Colors.grey.withValues(alpha: 0.2),
    };

    final progress = job.status == UploadJobStatus.uploading
        ? job.progress
        : (job.status == UploadJobStatus.completed ? 1.0 : job.progress);

    final showProgressIndicator = job.status == UploadJobStatus.uploading ||
        job.status == UploadJobStatus.paused ||
        job.status == UploadJobStatus.queued;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: Colors.black.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row containing type icon, filename, and state badge
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.2)),
                ),
                child: Icon(
                  _isVideo
                      ? Icons.videocam_rounded
                      : _isImage
                          ? Icons.image_rounded
                          : Icons.insert_drive_file_rounded,
                  color: statusColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_isVideo ? 'Video' : _isImage ? 'Image' : 'File'} • ${_humanBytes(job.totalBytes)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black45,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.2)),
                ),
                child: Text(
                  job.status.name.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 9.5,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),

          // Upload progress bar & details
          if (showProgressIndicator) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Colors.grey.shade100,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(progress * 100).toStringAsFixed(0)}% uploaded',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                Text(
                  '${_humanBytes(job.uploadedBytes)} of ${_humanBytes(job.totalBytes)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.black45,
                      ),
                ),
              ],
            ),
            if (job.status == UploadJobStatus.uploading) ...[
              const SizedBox(height: 6),
              Text(
                '${_formatSpeed()} • ${_formatRemaining()}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ],

          // Error Messages (if any)
          if (job.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.red.shade50.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade100),
              ),
              child: Text(
                job.errorMessage!,
                style: TextStyle(
                  color: Colors.red.shade900,
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                ),
              ),
            ),
          ],

          // Contextual Action Buttons
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (job.status == UploadJobStatus.uploading && onPause != null)
                TextButton.icon(
                  onPressed: onPause,
                  icon: const Icon(Icons.pause_rounded, size: 16),
                  label: const Text('Pause'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange.shade800,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              if (job.status == UploadJobStatus.paused && onResume != null)
                TextButton.icon(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('Resume'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              if (job.status == UploadJobStatus.failed && onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              if (!job.isDone) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey.shade700,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
