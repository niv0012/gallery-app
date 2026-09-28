import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../upload_job_model.dart';

/// Swipe-left-to-remove wrapper around an [UploadQueueTile].
///
/// * **Active job** (queued / uploading / paused): asks for confirmation
///   first, because removing it also cancels the transfer. [onRemove] must
///   cancel the request and drop the row (see `removeJob` in the queue
///   provider), so nothing keeps uploading in the background.
/// * **Finished job** (completed / failed / canceled): removed straight away
///   with an UNDO snackbar. Removing a completed row never deletes the media
///   that already reached the server — it only clears the queue entry.
///
/// [onRemove] has to update the list synchronously: a [Dismissible] must be
/// gone from the widget tree in the same frame it is dismissed.
class DismissibleUploadTile extends StatelessWidget {
  const DismissibleUploadTile({
    super.key,
    required this.job,
    required this.onRemove,
    required this.onRestore,
    required this.child,
  });

  final UploadJobModel job;
  final VoidCallback onRemove;

  /// Called by the snackbar's UNDO (finished jobs only).
  final VoidCallback onRestore;
  final Widget child;

  Future<bool> _confirmCancelAndRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        title: const Text('Cancel this upload?'),
        content: Text(
          '"${job.fileName}" has not finished uploading. It will be stopped '
          'and removed from the queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep uploading'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel & remove'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final wasActive = !job.isDone;

    return Dismissible(
      key: ValueKey('dismiss-upload-${job.id}'),
      direction: DismissDirection.endToStart,
      background: _SwipeBackground(
        icon: wasActive ? Icons.cancel_rounded : Icons.delete_outline_rounded,
        label: wasActive ? 'Cancel & remove' : 'Remove',
      ),
      confirmDismiss: (_) async {
        if (job.isDone) return true;
        return _confirmCancelAndRemove(context);
      },
      onDismissed: (_) {
        // Grab the messenger before the row (and its context) goes away.
        final messenger = ScaffoldMessenger.of(context);
        onRemove();
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(wasActive
                  ? 'Upload canceled and removed'
                  : 'Removed "${job.fileName}" from the list'),
              action: wasActive
                  ? null
                  : SnackBarAction(label: 'UNDO', onPressed: onRestore),
            ),
          );
      },
      child: child,
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    // Same outer margin / radius as UploadQueueTile so the red panel lines up
    // with the card being swiped away.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.only(right: 20),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: AppColors.error,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
