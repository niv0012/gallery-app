import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';
import '../../core/constants/app_constants.dart';
import '../../models/delete_preview_model.dart';
Future<DeleteMode?> showSafeDeleteDialog({
  required BuildContext context,
  required String itemName,
  required Future<DeletePreviewResponse> Function(DeleteMode mode) getPreview,
  bool isHidden = false,
}) async {
  return showDialog<DeleteMode>(
    context: context,
    builder: (ctx) => ProviderScope(
      child: _SafeDeleteDialog(itemName: itemName, getPreview: getPreview, isHidden: isHidden),
    ),
  );
}

class _SafeDeleteDialog extends StatefulWidget {
  const _SafeDeleteDialog({required this.itemName, required this.getPreview, required this.isHidden});
  final String itemName;
  final Future<DeletePreviewResponse> Function(DeleteMode mode) getPreview;
  final bool isHidden;

  @override
  State<_SafeDeleteDialog> createState() => _SafeDeleteDialogState();
}

class _SafeDeleteDialogState extends State<_SafeDeleteDialog> {
  DeleteMode _mode = DeleteMode.moveUp;
  Future<DeletePreviewResponse>? _previewFuture;
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchPreview();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _fetchPreview() {
    setState(() {
      _previewFuture = widget.getPreview(_mode);
    });
  }

  bool _canConfirm() {
    if (_mode == DeleteMode.moveUp && widget.isHidden) return false;
    if (_mode == DeleteMode.deleteAll && _nameController.text != widget.itemName) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      title: Text('Delete "${widget.itemName}"?', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What would you like to do with the items inside this folder?', style: TextStyle(color: context.textMuted)),
            const SizedBox(height: AppSpacing.md),
            RadioListTile<DeleteMode>(
              title: const Text('Move everything up'),
              subtitle: const Text('Keep the contents, just delete this folder.'),
              value: DeleteMode.moveUp,
              groupValue: _mode,
              onChanged: (val) {
                if (val != null) {
                  setState(() => _mode = val);
                  _fetchPreview();
                }
              },
            ),
            if (_mode == DeleteMode.moveUp && widget.isHidden)
              Padding(
                padding: const EdgeInsets.only(left: 48.0, right: 16.0, bottom: 8.0),
                child: Text(
                  'Hidden folders cannot be moved up. Please select "Delete everything" or unhide the folder first.',
                  style: TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ),
            RadioListTile<DeleteMode>(
              title: const Text('Delete everything'),
              subtitle: const Text('Move this folder and all its contents to the Trash.'),
              value: DeleteMode.deleteAll,
              groupValue: _mode,
              onChanged: (val) {
                if (val != null) {
                  setState(() => _mode = val);
                  _fetchPreview();
                }
              },
            ),
            if (_mode == DeleteMode.deleteAll)
              Padding(
                padding: const EdgeInsets.only(left: 48.0, right: 16.0, top: 8.0, bottom: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Type "${widget.itemName}" to confirm:', style: TextStyle(color: context.textPrimary, fontSize: 13)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            FutureBuilder<DeletePreviewResponse>(
              future: _previewFuture,
              builder: (ctx, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Text('Error loading preview: ${snapshot.error}', style: const TextStyle(color: AppColors.error));
                }
                if (snapshot.hasData) {
                  final data = snapshot.data!;
                  return Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: _mode == DeleteMode.deleteAll ? AppColors.error.withValues(alpha: 0.1) : context.borderColor,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('This action will ${_mode == DeleteMode.deleteAll ? 'delete' : 'move'}:', style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: AppSpacing.sm),
                        Text('• ${data.foldersAffected} Folders'),
                        Text('• ${data.albumsAffected} Albums'),
                        Text('• ${data.mediaAffected} Photos/Videos'),
                      ],
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text('Cancel', style: TextStyle(color: context.textMuted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: _canConfirm() ? () => Navigator.of(context).pop(_mode) : null,
          child: const Text('Confirm', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
