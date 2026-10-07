import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';
import '../../models/zip_job_model.dart';
import '../../providers/zip_job_provider.dart';

/// Shows all the user's recent server-side ZIP jobs and lets them download
/// or cancel each one. Jobs are auto-polled every 3 s while any are active.
class ZipJobsScreen extends ConsumerStatefulWidget {
  const ZipJobsScreen({super.key});

  @override
  ConsumerState<ZipJobsScreen> createState() => _ZipJobsScreenState();
}

class _ZipJobsScreenState extends ConsumerState<ZipJobsScreen> {
  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(zipJobsProvider);

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        title: Text(
          'ZIP Downloads',
          style: TextStyle(
            color: context.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: IconThemeData(color: context.textPrimary),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => ref.read(zipJobsProvider.notifier).refresh(),
          ),
        ],
      ),
      body: jobsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 48, color: AppColors.error),
              const SizedBox(height: AppSpacing.md),
              Text('Failed to load jobs', style: TextStyle(color: context.textMuted)),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => ref.read(zipJobsProvider.notifier).refresh(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (jobs) {
          if (jobs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (r) =>
                        AppColors.heroGradient.createShader(r),
                    child: const Icon(Icons.folder_zip_rounded,
                        size: 72, color: Colors.white),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'No ZIP downloads yet',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Create a ZIP from a folder or album details screen.',
                    style: TextStyle(color: context.textMuted, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.md),
            itemCount: jobs.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, i) => _ZipJobCard(job: jobs[i]),
          );
        },
      ),
    );
  }
}

class _ZipJobCard extends ConsumerWidget {
  const _ZipJobCard({required this.job});
  final ZipJobModel job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _statusColor(job.status);
    final icon = _statusIcon(job.status);

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            title: Text(
              job.kind == 'zip_folder' ? 'Folder ZIP' : 'Album ZIP',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            subtitle: Text(
              _formatDate(job.createdAt),
              style: TextStyle(fontSize: 12, color: context.textMuted),
            ),
            trailing: _StatusChip(status: job.status),
          ),

          // Progress bar (visible while active)
          if (job.isActive)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: job.progress / 100,
                      minHeight: 6,
                      backgroundColor:
                          AppColors.primary.withValues(alpha: 0.12),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(AppColors.primary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${job.progress}%',
                    style: TextStyle(fontSize: 11, color: context.textMuted),
                  ),
                ],
              ),
            ),

          // Error message
          if (job.status == ZipJobStatus.failed &&
              job.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 16, color: AppColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        job.errorMessage!,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Expiry warning
          if (job.status == ZipJobStatus.completed && job.expiresAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Text(
                job.isExpired
                    ? 'This link has expired.'
                    : 'Expires ${_formatDate(job.expiresAt!)}',
                style: TextStyle(
                  fontSize: 11,
                  color: job.isExpired
                      ? AppColors.error
                      : context.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            child: Row(
              children: [
                if (job.status == ZipJobStatus.completed &&
                    job.resultUrl != null &&
                    !job.isExpired)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _download(context, job.resultUrl!),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Download ZIP'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                if (job.isActive) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _cancel(context, ref, job.id),
                      icon: const Icon(Icons.cancel_outlined, size: 18),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: BorderSide(
                            color: AppColors.error.withValues(alpha: 0.5)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _download(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open download link.')),
        );
      }
    }
  }

  Future<void> _cancel(
      BuildContext context, WidgetRef ref, String jobId) async {
    await ref.read(zipJobsProvider.notifier).cancelJob(jobId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job cancelled.')),
      );
    }
  }

  Color _statusColor(ZipJobStatus status) => switch (status) {
        ZipJobStatus.pending => AppColors.warning,
        ZipJobStatus.processing => AppColors.primary,
        ZipJobStatus.completed => AppColors.success,
        ZipJobStatus.failed => AppColors.error,
        ZipJobStatus.canceled => AppColors.subtitle,
      };

  IconData _statusIcon(ZipJobStatus status) => switch (status) {
        ZipJobStatus.pending => Icons.hourglass_top_rounded,
        ZipJobStatus.processing => Icons.sync_rounded,
        ZipJobStatus.completed => Icons.check_circle_rounded,
        ZipJobStatus.failed => Icons.error_rounded,
        ZipJobStatus.canceled => Icons.cancel_rounded,
      };

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day}/${local.month}/${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final ZipJobStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ZipJobStatus.pending => AppColors.warning,
      ZipJobStatus.processing => AppColors.primary,
      ZipJobStatus.completed => AppColors.success,
      ZipJobStatus.failed => AppColors.error,
      ZipJobStatus.canceled => AppColors.subtitle,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
