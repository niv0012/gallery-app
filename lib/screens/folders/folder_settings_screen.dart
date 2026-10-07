import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../core/theme/theme_context.dart';
import '../../widgets/folders/safe_delete_dialog.dart';

/// Admin-only Folder Settings — reached from [FolderDetailsScreen].
/// Houses folder-level toggles and the destructive delete action.
class FolderSettingsScreen extends ConsumerWidget {
  final String folderId;

  const FolderSettingsScreen({super.key, required this.folderId});

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, dynamic folder) async {
    final folderRepo = ref.read(folderRepositoryProvider);
    final mode = await showSafeDeleteDialog(
      context: context,
      itemName: folder.name,
      getPreview: (mode) => folderRepo.previewDeleteFolder(folderId, mode: mode),
      isHidden: folder.isHidden,
    );

    if (mode != null) {
      await ref.read(folderAsyncProvider.notifier).deleteFolder(folderId, mode: mode);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('"${folder.name}" deleted')));
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

    // Fetch effective (ancestor-resolved) rules. While loading, fall back to
    // the folder's own values. The difference matters when own value is null:
    // the effective value shows what the rule would actually be in practice.
    final effectiveRulesAsync = ref.watch(folderEffectiveRulesProvider(folderId));
    final effectiveRules = effectiveRulesAsync.valueOrNull;

    final ownAllowDownload = folder.allowDownload;
    final ownShowWatermark = folder.showWatermark;

    // Effective resolved values (from ancestor walk):
    final effectiveAllowDownload = effectiveRules != null
        ? effectiveRules['effective_allow_download'] as bool?
        : null;
    final effectiveShowWatermark = effectiveRules != null
        ? effectiveRules['effective_show_watermark'] as bool?
        : null;

    // Ancestor source names if inherited from a specific parent
    final allowDownloadSource = effectiveRules != null
        ? (effectiveRules['allow_download_source'] as Map<String, dynamic>?)
        : null;
    final showWatermarkSource = effectiveRules != null
        ? (effectiveRules['show_watermark_source'] as Map<String, dynamic>?)
        : null;

    // Subtitle for the rule tile: show effective value + source when inherited
    String allowDownloadSubtitle() {
      if (ownAllowDownload != null) {
        return ownAllowDownload ? 'Allowed (set on this folder)' : 'Blocked (set on this folder)';
      }
      final sourceName = allowDownloadSource?['name'] as String?;
      final inherited = sourceName != null ? 'Inherited from "$sourceName"' : 'Inherited from parent';
      if (effectiveAllowDownload == null) return inherited;
      return effectiveAllowDownload
          ? 'Allowed ($inherited)'
          : 'Blocked ($inherited)';
    }

    String showWatermarkSubtitle() {
      if (ownShowWatermark != null) {
        return ownShowWatermark ? 'Enabled (set on this folder)' : 'Disabled (set on this folder)';
      }
      final sourceName = showWatermarkSource?['name'] as String?;
      final inherited = sourceName != null ? 'Inherited from "$sourceName"' : 'Inherited from parent';
      if (effectiveShowWatermark == null) return inherited;
      return effectiveShowWatermark
          ? 'Enabled ($inherited)'
          : 'Disabled ($inherited)';
    }

    return Scaffold(
      appBar: const CustomAppBar(title: 'Folder Settings', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // ── Visibility ─────────────────────────────────────────────
            _SectionCard(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hide from Client Gallery',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text(
                      'Keeps this folder and its albums out of the read-only client view.'),
                  value: folder.isHidden,
                  onChanged: (v) =>
                      ref.read(folderProvider).setHidden(folder.id, v),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),

            // ── Download & Watermark Rules ──────────────────────────────
            Text('Download & Watermark Rules',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary,
                    fontSize: 14)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'These rules apply to all albums and sub-folders inside this folder. '
              'Leave both as "Inherit" to follow the nearest parent rule (default: downloads on, watermark off).',
              style: TextStyle(
                  fontSize: 12,
                  color: context.textPrimary.withOpacity(0.55)),
            ),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              children: [
                // Allow Download
                _RuleTile(
                  icon: Icons.download_rounded,
                  title: 'Allow Download',
                  subtitle: allowDownloadSubtitle(),
                  value: ownAllowDownload,
                  isInherited: ownAllowDownload == null,
                  effectiveValue: effectiveAllowDownload,
                  onChanged: (v) => ref.read(folderProvider).setRules(
                        folder.id,
                        allowDownload: v,
                        showWatermark: folder.showWatermark,
                      ),
                  onClearInherit: () => ref.read(folderProvider).setRules(
                        folder.id,
                        allowDownload: null,
                        showWatermark: folder.showWatermark,
                      ),
                ),
                const Divider(height: 1, indent: 52),
                // Show Watermark
                _RuleTile(
                  icon: Icons.branding_watermark_rounded,
                  title: 'Show Watermark',
                  subtitle: showWatermarkSubtitle(),
                  value: ownShowWatermark,
                  isInherited: ownShowWatermark == null,
                  effectiveValue: effectiveShowWatermark,
                  onChanged: (v) => ref.read(folderProvider).setRules(
                        folder.id,
                        allowDownload: folder.allowDownload,
                        showWatermark: v,
                      ),
                  onClearInherit: () => ref.read(folderProvider).setRules(
                        folder.id,
                        allowDownload: folder.allowDownload,
                        showWatermark: null,
                      ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),

            // ── Danger Zone ─────────────────────────────────────────────
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
                onPressed: () => _confirmDelete(context, ref, folder),
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

// ─────────────────────────────────────────────────────────────────────────────
// Helper widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(children: children),
    );
  }
}

/// A three-state rule tile: true / false / null (inherit).
/// When [isInherited] is true, [effectiveValue] drives the Switch appearance
/// so the user sees what value would actually apply.
class _RuleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool? value;
  final bool? effectiveValue;
  final bool isInherited;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onClearInherit;

  const _RuleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.isInherited,
    required this.onChanged,
    required this.onClearInherit,
    this.effectiveValue,
  });

  @override
  Widget build(BuildContext context) {
    // When inherited show the resolved effective value; fall back to false.
    final switchValue = value ?? effectiveValue ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 20, color: context.textPrimary.withOpacity(0.6)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12,
                        color: isInherited
                            ? context.textPrimary.withOpacity(0.45)
                            : context.textPrimary.withOpacity(0.7))),
              ],
            ),
          ),
          // "Inherit" clear button shown when rule is explicitly set
          if (!isInherited)
            GestureDetector(
              onTap: onClearInherit,
              child: Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Tooltip(
                  message: 'Reset to inherit',
                  child: Icon(Icons.refresh_rounded,
                      size: 16,
                      color: context.textPrimary.withOpacity(0.4)),
                ),
              ),
            ),
          // When inherited, show ghost switch (slightly dimmed) but still interactive
          Opacity(
            opacity: isInherited ? 0.55 : 1.0,
            child: Switch(
              value: switchValue,
              onChanged: (v) => onChanged(v),
            ),
          ),
        ],
      ),
    );
  }
}
