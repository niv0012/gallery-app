import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/user.dart';
import '../../providers/auth_providers.dart';
import '../../providers/drawer_provider.dart';
import '../../upload/upload_job_model.dart';
import '../../upload/upload_queue_provider.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/navigation/admin_bottom_nav.dart';

import 'admin_clients_screen.dart';
import 'admin_dashboard_screen.dart';
import 'admin_gallery_screen.dart';
import 'admin_profile_screen.dart';
import '../../core/theme/theme_context.dart';

/// The single post-login Scaffold for the Photographer / Studio Owner role.
///
/// Wraps the 5 studio-admin destinations and injects a global Background Upload Indicator
/// above the bottom navigation bar when background uploads are active.
class AdminMainNavScreen extends ConsumerStatefulWidget {
  const AdminMainNavScreen({super.key});

  @override
  ConsumerState<AdminMainNavScreen> createState() => _AdminMainNavScreenState();
}

class _AdminMainNavScreenState extends ConsumerState<AdminMainNavScreen> {
  int _navIndex = 1;

  void _goToTab(int index) {
    setState(() => _navIndex = index);
    // Keep the drawer highlight in sync with the bottom nav.
    const ids = {0: 'dashboard', 1: 'gallery', 2: 'clients'};
    final id = ids[index];
    if (id != null) ref.read(selectedDrawerItemProvider.notifier).select(id);
  }

  late final _tabs = [
    StudioDashboardScreen(onNavigateToTab: _goToTab),
    const AdminGalleryScreen(),
    const AdminClientsScreen(),
    const AdminProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final authUser = ref.watch(authProvider).valueOrNull;
    if (authUser != null && authUser.role == AppUserRole.client) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        }
      });
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    return Scaffold(
      body: ScreenBackdrop(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(index: _navIndex, children: _tabs),
              ),
              const BackgroundUploadIndicator(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: AdminBottomNav(
        currentIndex: _navIndex,
        onTap: _goToTab,
      ),
    );
  }
}

/// A floating card indicator that reveals background upload progress, speeds,
/// and fast control triggers across any dashboard navigations.
class BackgroundUploadIndicator extends ConsumerWidget {
  const BackgroundUploadIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueStateAsync = ref.watch(uploadQueueProvider);

    return queueStateAsync.when(
      loading: () => SizedBox.shrink(),
      error: (_, __) => SizedBox.shrink(),
      data: (state) {
        final activeJobs = state.jobs.where((j) => !j.isDone).toList();
        if (activeJobs.isEmpty) return SizedBox.shrink();

        final isProcessing = state.isProcessing;
        final completedCount = state.completedCount;
        final totalCount = state.jobs.length;
        final progress = state.overallProgress;

        return Card(
          margin: EdgeInsets.fromLTRB(16, 0, 16, 12),
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: InkWell(
            onTap: () {
              Navigator.of(context).pushNamed(AppRoutes.uploadQueue);
            },
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.black.withValues(alpha: 0.04)),
                color: context.surfaceColor.withValues(alpha: 0.96),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: (isProcessing ? AppColors.primary : Colors.orange)
                          .withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isProcessing
                          ? Icons.cloud_upload_rounded
                          : Icons.pause_circle_filled_rounded,
                      color: isProcessing
                          ? AppColors.primary
                          : Colors.orange.shade800,
                      size: 16,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isProcessing
                                  ? 'Uploading: $completedCount of $totalCount done'
                                  : 'Uploads Paused ($completedCount of $totalCount done)',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: context.textPrimary,
                              ),
                            ),
                            Text(
                              '${(progress * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: isProcessing
                                    ? AppColors.primary
                                    : Colors.orange.shade900,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: Colors.grey.shade100,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isProcessing
                                  ? AppColors.primary
                                  : Colors.orange.shade600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isProcessing)
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(Icons.pause_rounded,
                              size: 20, color: Colors.orange),
                          onPressed: () =>
                              ref.read(uploadQueueProvider.notifier).pauseAll(),
                        )
                      else if (state.jobs
                          .any((j) => j.status == UploadJobStatus.paused))
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(Icons.play_arrow_rounded,
                              size: 20, color: AppColors.primary),
                          onPressed: () => ref
                              .read(uploadQueueProvider.notifier)
                              .resumeAll(),
                        ),
                      SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(Icons.cancel_rounded,
                            size: 20, color: Colors.grey.shade500),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text('Cancel Uploads?'),
                              content: Text(
                                  'Cancel all pending and active background uploads?'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text('No')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: Text('Yes, Cancel')),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            ref.read(uploadQueueProvider.notifier).cancelAll();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
