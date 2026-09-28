import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/folder_model.dart';
import '../../providers/folder_provider.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/anchored_dropdown_field.dart';
import '../../core/theme/theme_context.dart';

/// Admin-only Create Folder — reached from [FolderListScreen]'s FAB.
/// Optionally nests the new folder under an existing one (feeds Move
/// Folder's same parent concept).
class CreateFolderScreen extends ConsumerStatefulWidget {
  /// Optional pre-selected parent, e.g. when creating a folder from
  /// inside another folder's details in a future flow.
  final String? parentId;

  const CreateFolderScreen({super.key, this.parentId});

  @override
  ConsumerState<CreateFolderScreen> createState() => _CreateFolderScreenState();
}

class _CreateFolderScreenState extends ConsumerState<CreateFolderScreen> {
  final _nameController = TextEditingController();
  String? _parentId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _parentId = widget.parentId;
    // Eagerly trigger a folder load so the parent picker is populated
    // even when this screen is the first in the session to watch folderProvider.
    Future.microtask(() {
      if (!mounted) return;
      final state = ref.read(folderProvider);
      if (state.folders.isEmpty && !state.isLoading) {
        state.load();
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Folder name is required');
      return;
    }

    final controller = ref.read(folderProvider);
    try {
      await controller.createFolder(name: name, parentId: _parentId);
      if (!mounted) return;
      setState(() => _error = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Folder "$name" created')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderState = ref.watch(folderProvider);
    final allFolders = folderState.folders;
    final isLoadingFolders = folderState.isLoading && allFolders.isEmpty;

    String folderPath(FolderModel f) {
      final ancestors = folderState.ancestorsOf(f.id);
      if (ancestors.isEmpty) return f.name;
      return '${ancestors.map((a) => a.name).join(' / ')} / ${f.name}';
    }

    // Build the dropdown items. Guard: value must exist in items, so only
    // include _parentId as initial value when its folder is already loaded.
    final parentExists =
        _parentId == null || allFolders.any((f) => f.id == _parentId);
    final effectiveParentId = parentExists ? _parentId : null;

    return Scaffold(
      appBar: const CustomAppBar(title: 'Create Folder', showBack: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: constraints.maxHeight, maxWidth: 520),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_error != null) ...[
                            Text(
                              _error!,
                              style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                          TextField(
                            controller: _nameController,
                            decoration:
                                const InputDecoration(labelText: 'Folder name'),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: AppSpacing.md),

                          // Parent folder picker — shows a loading indicator
                          // while folders are still being fetched so the user
                          // knows to wait instead of seeing an empty dropdown.
                          if (isLoadingFolders)
                            InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Parent folder (optional)',
                              ),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Text(
                                    'Loading folders…',
                                    style: TextStyle(
                                      color: context.textMuted,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            AnchoredDropdownField<String?>(
                              key: ValueKey(effectiveParentId),
                              value: effectiveParentId,
                              decoration: const InputDecoration(
                                labelText: 'Parent folder (optional)',
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('No parent — root level'),
                                ),
                                ...allFolders.map(
                                  (FolderModel f) => DropdownMenuItem<String?>(
                                    value: f.id,
                                    child: Text(
                                      folderPath(f),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: (v) => setState(() => _parentId = v),
                            ),
                          const Spacer(),
                          const SizedBox(height: AppSpacing.lg),
                          GradientButton(
                              label: 'Create Folder', onPressed: _submit),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
