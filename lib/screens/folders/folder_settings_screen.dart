import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';

/// Admin-only Folder Settings — reached from [FolderDetailsScreen].
/// Houses folder-level toggles and the destructive delete action.
class FolderSettingsScreen extends ConsumerWidget {
  final String folderId;

  const FolderSettingsScreen({super.key, required this.folderId});

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text(
            'This will remove "$name". Albums inside will be unfiled, not deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(folderProvider).deleteFolder(folderId);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('"$name" deleted')));
        // Settings was pushed from Details, which was pushed from Folder
        // List — two pops lands back on the list.
        final nav = Navigator.of(context);
        nav.pop();
        if (nav.canPop()) nav.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folderState = ref.watch(folderProvider);
    final folder = folderState.folderById(folderId);

    if (folder == null) {
      return const Scaffold(
        appBar: CustomAppBar(title: 'Folder Settings', showBack: true),
        body: Center(child: Text('Folder not found')),
      );
    }

    return Scaffold(
      appBar: const CustomAppBar(title: 'Folder Settings', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: context.borderColor),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Hide from Client Gallery',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text(
                    'Keeps this folder and its albums out of the read-only client view.'),
                value: folder.isHidden,
                onChanged: (v) =>
                    ref.read(folderProvider).setHidden(folder.id, v),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('Danger zone',
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: context.textPrimary)),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                onPressed: () => _confirmDelete(context, ref, folder.name),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete Folder'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
