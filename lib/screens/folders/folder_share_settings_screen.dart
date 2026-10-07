import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';
import '../../models/album_model.dart';
import '../../models/share_link_model.dart';
import '../../providers/album_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/share_link_provider.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../../providers/auth_providers.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/face_search_provider.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/inputs/custom_text_field.dart';

/// Studio share-settings for a **Folder** share link — multi-album
/// checklist (task 5.4). One link per folder; editing which albums are
/// included never changes the token (plan §5.1). Hidden albums are shown
/// disabled so the photographer can see them but cannot include them.
class FolderShareSettingsScreen extends ConsumerStatefulWidget {
  final String folderId;
  final String folderName;
  final GalleryShareLink? link;

  const FolderShareSettingsScreen({
    super.key,
    required this.folderId,
    required this.folderName,
    this.link,
  });

  @override
  ConsumerState<FolderShareSettingsScreen> createState() =>
      _FolderShareSettingsScreenState();
}

/// Determines the top-level scope of the share link.
enum _ScopeMode {
  everything, // include_all = true (live, recursive)
  choose,     // manual pick of sub-folders / albums / loose items
}

enum _ShareMode { public, client, private }

class _FolderShareSettingsScreenState
    extends ConsumerState<FolderShareSettingsScreen> {
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _initialized = false;

  // ── Scope ──
  _ScopeMode _scopeMode = _ScopeMode.everything;
  /// Whether to include loose items directly in the root folder (album_id IS NULL).
  bool _includeFolderItems = false;
  /// Sub-folders whose entire subtree is shared (share_link_folders rows).
  final Set<String> _selectedFolderIds = {};
  /// Albums explicitly shared (share_link_albums rows) — used only in choose mode
  /// when include_all is false.
  final Set<String> _selectedAlbumIds = {};
  bool _autoIncludeNew = false;

  // ── Link options ──
  _ShareMode _shareMode = _ShareMode.public;
  String? _selectedClientId;
  bool _hasExpiry = false;
  DateTime? _expiryDate;
  bool _allowDownload = true;
  bool _showWatermark = false;
  bool _requireFaceSearch = false;

  bool _isSaving = false;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _generatePasscode() {
    final rand = Random.secure();
    setState(() {
      _passwordCtrl.text = (100000 + rand.nextInt(900000)).toString();
    });
  }

  void _initFields(GalleryShareLink? link, List<AlbumModel> folderAlbums) {
    if (_initialized) return;
    _initialized = true;

    if (link != null && !link.isRevoked) {
      // Restore scope mode
      _scopeMode = link.includeAll ? _ScopeMode.everything : _ScopeMode.choose;
      _includeFolderItems = link.includeFolderItems;
      _selectedFolderIds
        ..clear()
        ..addAll(link.folderIds);
      _selectedAlbumIds
        ..clear()
        ..addAll(link.albumIds);
      _autoIncludeNew = link.autoIncludeNew;

      if (link.hasPassword) {
        _shareMode = _ShareMode.private;
      } else if (link.clientId != null) {
        _shareMode = _ShareMode.client;
      } else {
        _shareMode = _ShareMode.public;
      }
      _selectedClientId = link.clientId;
      _hasExpiry = link.expiresAt != null;
      _expiryDate = link.expiresAt;
      _allowDownload = link.allowDownload;
      _showWatermark = link.showWatermark;
      _requireFaceSearch = link.kind == 'face_search';
    } else {
      // Default: everything mode
      _scopeMode = _ScopeMode.everything;
    }
    _checkIndexStatus();
  }

  Map<String, dynamic>? _indexStatus;

  Future<void> _checkIndexStatus() async {
    // In everything mode, we still want the face-index status
    final albumsToCheck = _scopeMode == _ScopeMode.everything
        ? <String>[] // skip — would need all folder albums
        : _selectedAlbumIds.toList();
    if (albumsToCheck.isEmpty) return;
    try {
      final repo = ref.read(faceRepositoryProvider);
      final status = await repo.getFaceIndexStatus(albumIds: albumsToCheck);
      if (mounted) setState(() => _indexStatus = status);
    } catch (_) {}
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final initial = _expiryDate ?? now.add(const Duration(days: 7));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _expiryDate =
            DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      });
    }
  }

  Future<void> _save(GalleryShareLink? existing) async {
    // Validate scope
    if (_scopeMode == _ScopeMode.choose) {
      final hasContent = _includeFolderItems ||
          _selectedFolderIds.isNotEmpty ||
          _selectedAlbumIds.isNotEmpty;
      if (!hasContent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Select at least one item, sub-folder, or album to share.')),
        );
        return;
      }
    }
    final hasExistingPw =
        existing != null && !existing.isRevoked && existing.hasPassword;
    if (_shareMode == _ShareMode.private &&
        !hasExistingPw &&
        !_formKey.currentState!.validate()) return;
    if (_shareMode == _ShareMode.private &&
        hasExistingPw &&
        _passwordCtrl.text.isNotEmpty) {
      if (!_formKey.currentState!.validate()) return;
    }
    if (_shareMode == _ShareMode.client && _selectedClientId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a client.')),
      );
      return;
    }

    final includeAll = _scopeMode == _ScopeMode.everything;

    setState(() => _isSaving = true);
    try {
      final controller = ref.read(
          shareLinkControllerProvider(ShareTarget(folderId: widget.folderId))
              .notifier);
      if (existing == null) {
        await controller.createLink(
          includeAll: includeAll,
          includeFolderItems: !includeAll && _includeFolderItems,
          albumIds: includeAll ? null : _selectedAlbumIds.toList(),
          folderIds: includeAll ? null : _selectedFolderIds.toList(),
          autoIncludeNew: _autoIncludeNew,
          clientId: _shareMode == _ShareMode.client ? _selectedClientId : null,
          password: _shareMode == _ShareMode.private
              ? (_passwordCtrl.text.isEmpty ? null : _passwordCtrl.text)
              : null,
          expiresAt: _hasExpiry ? _expiryDate : null,
          allowDownload: _allowDownload,
          showWatermark: _showWatermark,
          kind: _requireFaceSearch ? 'face_search' : 'standard',
        );
      } else {
        await controller.updateLink(
          id: existing.id,
          includeAll: includeAll,
          includeFolderItems: !includeAll && _includeFolderItems,
          albumIds: includeAll ? [] : _selectedAlbumIds.toList(),
          folderIds: includeAll ? [] : _selectedFolderIds.toList(),
          autoIncludeNew: _autoIncludeNew,
          clientId: _shareMode == _ShareMode.client ? _selectedClientId : null,
          clearClient: _shareMode != _ShareMode.client,
          password: _shareMode == _ShareMode.private
              ? (_passwordCtrl.text.isEmpty ? null : _passwordCtrl.text)
              : null,
          clearPassword: _shareMode != _ShareMode.private,
          expiresAt: _hasExpiry ? _expiryDate : null,
          clearExpiry: !_hasExpiry,
          allowDownload: _allowDownload,
          showWatermark: _showWatermark,
          kind: _requireFaceSearch ? 'face_search' : 'standard',
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Folder share link saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save: $e")),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _revoke(GalleryShareLink existing) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Folder Share Link?'),
        content: const Text(
            'Clients will immediately lose access to all albums in this link.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(shareLinkControllerProvider(ShareTarget(folderId: widget.folderId))
              .notifier)
          .revoke(existing.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Folder share link revoked.')));
      Navigator.of(context).pop(); // Go back to links list
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't revoke: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumState = ref.watch(albumProvider);
    final folderState = ref.watch(folderProvider);
    final albums = albumState.allAlbums;

    // Find all descendant folder IDs
    final Set<String> descendantFolderIds = {widget.folderId};
    bool added;
    do {
      added = false;
      for (final f in folderState.folders) {
        if (f.parentId != null && descendantFolderIds.contains(f.parentId) && !descendantFolderIds.contains(f.id)) {
          descendantFolderIds.add(f.id);
          added = true;
        }
      }
    } while (added);

    // Albums belonging to this folder or any descendant, sorted by updatedAt desc
    final folderAlbums = albums
        .where((a) => a.folderId != null && descendantFolderIds.contains(a.folderId) && a.deletedAt == null)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    // Set of hidden folder IDs — albums in hidden folders must be locked (plan §5.4a)
    final explicitHiddenFolderIds = folderState.folders
        .where((f) => f.isHidden)
        .map((f) => f.id)
        .toSet();
    
    final hiddenFolderIds = Set<String>.from(explicitHiddenFolderIds);
    bool hiddenAdded;
    do {
      hiddenAdded = false;
      for (final f in folderState.folders) {
        if (f.parentId != null && hiddenFolderIds.contains(f.parentId) && !hiddenFolderIds.contains(f.id)) {
          hiddenFolderIds.add(f.id);
          hiddenAdded = true;
        }
      }
    } while (hiddenAdded);

    final linkState = ref.watch(
        shareLinkControllerProvider(ShareTarget(folderId: widget.folderId)));
    
    // Check if the passed-in link is still valid in the controller list
    GalleryShareLink? activeLink = widget.link;
    if (activeLink != null) {
      final updated = linkState.activeLinks.where((l) => l.id == activeLink!.id).firstOrNull;
      if (updated != null) {
        activeLink = updated;
      }
    }
    
    final hasActiveLink = activeLink != null && !activeLink.isRevoked;

    _initFields(activeLink, folderAlbums);

    final connectedClients = ref
        .read(connectionsProvider.notifier)
        .connectedClientsForStudio(
          ref.read(authStateProvider).user?.id ?? '',
        );

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Share "${widget.folderName}"',
        showBack: true,
      ),
      body: SafeArea(
        child: linkState.isLoading && activeLink == null
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth:
                                min(constraints.maxWidth, 560)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // ── Active link banner ──────────────────────────
                            if (hasActiveLink) ...[
                              _LinkBanner(
                                link: activeLink!,
                                onRevoke: () => _revoke(activeLink!),
                              ),
                              const SizedBox(height: AppSpacing.xl),
                            ],

                            // ── Section: Scope / Content ─────────────────────
                            const _SectionHeader(
                                icon: Icons.folder_open_outlined,
                                label: 'What to Share'),
                            const SizedBox(height: AppSpacing.sm),
                            _SettingCard(
                              child: Column(
                                children: [
                                  RadioListTile<_ScopeMode>(
                                    dense: true,
                                    value: _ScopeMode.everything,
                                    groupValue: _scopeMode,
                                    onChanged: (v) =>
                                        setState(() => _scopeMode = v!),
                                    title: Row(
                                      children: [
                                        Icon(Icons.all_inclusive_rounded,
                                            size: 16,
                                            color: AppColors.primary),
                                        const SizedBox(width: 8),
                                        const Text('Everything in this folder',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                    subtitle: Text(
                                      'All sub-folders, albums & loose items — updates live as content is added.',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.textPrimary
                                              .withOpacity(0.55)),
                                    ),
                                  ),
                                  const Divider(height: 1),
                                  RadioListTile<_ScopeMode>(
                                    dense: true,
                                    value: _ScopeMode.choose,
                                    groupValue: _scopeMode,
                                    onChanged: (v) =>
                                        setState(() => _scopeMode = v!),
                                    title: Row(
                                      children: [
                                        Icon(Icons.checklist_rounded,
                                            size: 16,
                                            color: AppColors.primary),
                                        const SizedBox(width: 8),
                                        const Text('Choose what to share',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                    subtitle: Text(
                                      'Pick specific sub-folders, albums and loose items.',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.textPrimary
                                              .withOpacity(0.55)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),

                            // ── Tree (visible only in choose mode) ───────────
                            if (_scopeMode == _ScopeMode.choose) ...[
                              _ContentTree(
                                rootFolderId: widget.folderId,
                                folderAlbums: folderAlbums,
                                folderState: folderState,
                                hiddenFolderIds: hiddenFolderIds,
                                selectedFolderIds: _selectedFolderIds,
                                selectedAlbumIds: _selectedAlbumIds,
                                includeFolderItems: _includeFolderItems,
                                onFolderToggle: (id, checked) =>
                                    setState(() {
                                  if (checked) {
                                    _selectedFolderIds.add(id);
                                  } else {
                                    _selectedFolderIds.remove(id);
                                  }
                                }),
                                onAlbumToggle: (id, checked) =>
                                    setState(() {
                                  if (checked) {
                                    _selectedAlbumIds.add(id);
                                  } else {
                                    _selectedAlbumIds.remove(id);
                                  }
                                }),
                                onLooseItemsToggle: (v) => setState(
                                    () => _includeFolderItems = v),
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],

                            // Auto-include toggle (only for choose mode)
                            if (_scopeMode == _ScopeMode.choose) ...[
                              _SettingCard(
                                child: SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                      'Auto-include new albums',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: const Text(
                                      'Albums added to this folder later are '
                                      'automatically included in this link.'),
                                  value: _autoIncludeNew,
                                  onChanged: (v) =>
                                      setState(() => _autoIncludeNew = v),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xl),
                            ] else
                              const SizedBox(height: AppSpacing.xl),


                            // ── Section: Share type ─────────────────────────
                            _SectionHeader(
                                icon: Icons.lock_outline_rounded,
                                label: 'Access Type'),
                            const SizedBox(height: AppSpacing.sm),
                            _SettingCard(
                              child: Column(
                                children: [
                                  _ModeRadio(
                                    icon: Icons.public_rounded,
                                    label: 'Public',
                                    subtitle: 'Anyone with the link',
                                    value: _ShareMode.public,
                                    groupValue: _shareMode,
                                    onChanged: (v) =>
                                        setState(() => _shareMode = v!),
                                  ),
                                  const Divider(height: 1),
                                  _ModeRadio(
                                    icon: Icons.person_outline_rounded,
                                    label: 'Client-only',
                                    subtitle:
                                        'Only the selected connected client',
                                    value: _ShareMode.client,
                                    groupValue: _shareMode,
                                    onChanged: (v) =>
                                        setState(() => _shareMode = v!),
                                  ),
                                  if (_shareMode == _ShareMode.client) ...[
                                    const Divider(height: 1),
                                    _ClientPicker(
                                      clients: connectedClients,
                                      selectedId: _selectedClientId,
                                      onSelected: (id) => setState(
                                          () => _selectedClientId = id),
                                    ),
                                  ],
                                  const Divider(height: 1),
                                  _ModeRadio(
                                    icon: Icons.vpn_key_outlined,
                                    label: 'Password-protected',
                                    subtitle:
                                        'Anyone with the link and the passcode',
                                    value: _ShareMode.private,
                                    groupValue: _shareMode,
                                    onChanged: (v) =>
                                        setState(() => _shareMode = v!),
                                  ),
                                  if (_shareMode == _ShareMode.private)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          AppSpacing.md, 0, AppSpacing.md,
                                          AppSpacing.md),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: CustomTextField(
                                              controller: _passwordCtrl,
                                              icon: Icons.pin_outlined,
                                              label: activeLink != null &&
                                                      activeLink.hasPassword
                                                  ? 'Change passcode (leave blank to keep)'
                                                  : 'Passcode (6 digits)',
                                              keyboardType:
                                                  TextInputType.number,
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .digitsOnly,
                                                LengthLimitingTextInputFormatter(
                                                    6),
                                              ],
                                              validator: activeLink != null &&
                                                      activeLink.hasPassword &&
                                                      _passwordCtrl.text.isEmpty
                                                  ? null
                                                  : (v) => v != null &&
                                                          v.isNotEmpty &&
                                                          v.length < 6
                                                      ? 'Must be 6 digits'
                                                      : null,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          TextButton(
                                            onPressed: _generatePasscode,
                                            child: const Text('Generate'),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // ── Section: Options ────────────────────────────
                            _SectionHeader(
                                icon: Icons.tune_rounded, label: 'Options'),
                            const SizedBox(height: AppSpacing.sm),
                            _SettingCard(
                              child: Column(
                                children: [
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Allow Download',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: const Text(
                                        'Clients can save photos to their device.'),
                                    value: _allowDownload,
                                    onChanged: (v) =>
                                        setState(() => _allowDownload = v),
                                  ),
                                  const Divider(height: 1),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Show Watermark',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: const Text(
                                        'Overlay your studio watermark on previews.'),
                                    value: _showWatermark,
                                    onChanged: (v) =>
                                        setState(() => _showWatermark = v),
                                  ),
                                  const Divider(height: 1),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Require Face Search',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: const Text(
                                        'Guests must upload a selfie to view only their photos.'),
                                    value: _requireFaceSearch,
                                    onChanged: (v) =>
                                        setState(() => _requireFaceSearch = v),
                                  ),
                                  if (_requireFaceSearch)
                                    _buildFaceIndexWarning(context),
                                  const Divider(height: 1),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Set Expiry Date',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: _hasExpiry && _expiryDate != null
                                        ? Text(
                                            'Expires ${_expiryDate!.toLocal().toString().split(' ').first}')
                                        : const Text('Link never expires.'),
                                    value: _hasExpiry,
                                    onChanged: (v) async {
                                      setState(() => _hasExpiry = v);
                                      if (v) await _pickExpiry();
                                    },
                                  ),
                                  if (_hasExpiry && _expiryDate != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                          bottom: AppSpacing.sm,
                                          left: AppSpacing.sm),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton.icon(
                                          onPressed: _pickExpiry,
                                          icon: const Icon(Icons.edit_calendar_rounded, size: 16),
                                          label: const Text('Change date'),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),

                            // ── Save button ─────────────────────────────────
                            GradientButton(
                              onPressed: _isSaving ? null : () => _save(activeLink),
                              isLoading: _isSaving,
                              label: hasActiveLink
                                  ? 'Update Share Link'
                                  : 'Create Share Link',
                            ),
                            const SizedBox(height: AppSpacing.xl),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildFaceIndexWarning(BuildContext context) {
    final status = _indexStatus;
    if (status == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    final total = (status['total_photos'] as num?)?.toInt() ?? 0;
    final indexed = (status['indexed_photos'] as num?)?.toInt() ?? 0;
    if (total == 0 || indexed >= total) return const SizedBox.shrink();

    final unindexed = total - indexed;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Face index incomplete — $unindexed of $total photos unindexed',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.orange.shade800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange.shade800,
                      side: BorderSide(color: Colors.orange.shade400),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      for (final albumId in _selectedAlbumIds) {
                        try {
                          await ref.read(apiClientProvider).post(
                            '/faces/reindex?album_id=$albumId',
                            body: {},
                            withAuth: true,
                          );
                        } catch (_) {}
                      }
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Face indexing started in background.')),
                      );
                      await Future.delayed(const Duration(seconds: 3));
                      await _checkIndexStatus();
                    },
                    icon: const Icon(Icons.autorenew_rounded, size: 13),
                    label: const Text('Start indexing', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                color: context.textPrimary,
                fontSize: 14)),
      ],
    );
  }
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.textPrimary.withValues(alpha: 0.08)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: child,
    );
  }
}



class _LinkBanner extends StatelessWidget {
  const _LinkBanner({required this.link, required this.onRevoke});
  final GalleryShareLink link;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final url = link.primaryShareUrl;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withOpacity(0.12),
            AppColors.accent.withOpacity(0.08)
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link_rounded,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              const Text('Active Share Link',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
              const Spacer(),
              _StatChip(
                  icon: Icons.visibility_outlined,
                  value: link.viewsCount.toString()),
              const SizedBox(width: 6),
              _StatChip(
                  icon: Icons.download_outlined,
                  value: link.downloadsCount.toString()),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            url,
            style: TextStyle(
                fontSize: 12,
                color: context.textPrimary.withOpacity(0.65),
                fontFamily: 'monospace'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),

          // QR code
          Center(
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 140,
              eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: AppColors.primary),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black87),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Action buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied!')));
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy'),
              ),
              OutlinedButton.icon(
                onPressed: () => Share.share(url,
                    subject: 'View my photo gallery'),
                icon: const Icon(Icons.share_rounded, size: 16),
                label: const Text('Share'),
              ),
              OutlinedButton.icon(
                onPressed: () => launchUrlString(url, mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                label: const Text('Open'),
              ),
              OutlinedButton.icon(
                style:
                    OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                onPressed: onRevoke,
                icon: const Icon(Icons.link_off_rounded, size: 16),
                label: const Text('Revoke'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.value});
  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary)),
        ],
      ),
    );
  }
}

class _ModeRadio extends StatelessWidget {
  const _ModeRadio({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final _ShareMode value;
  final _ShareMode groupValue;
  final ValueChanged<_ShareMode?> onChanged;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<_ShareMode>(
      dense: true,
      value: value,
      groupValue: groupValue,
      onChanged: onChanged,
      title: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      subtitle: Text(subtitle,
          style: TextStyle(
              fontSize: 12,
              color: context.textPrimary.withOpacity(0.55))),
    );
  }
}

class _ClientPicker extends StatelessWidget {
  const _ClientPicker({
    required this.clients,
    required this.selectedId,
    required this.onSelected,
  });

  final List<StudioClientConnection> clients;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (clients.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          'No connected clients yet. Connect a client first.',
          style: TextStyle(
              fontSize: 12, color: context.textPrimary.withOpacity(0.55)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
      child: DropdownButtonFormField<String>(
        value: selectedId,
        hint: const Text('Select client'),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        items: clients
            .map((c) => DropdownMenuItem(
                  value: c.id,
                  child: Text(c.clientData?.name != null && c.clientData!.name.isNotEmpty ? c.clientData!.name : c.id),
                ))
            .toList(),
        onChanged: onSelected,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ContentTree — renders the "Choose what to share" tree
// ─────────────────────────────────────────────────────────────────────────────

class _ContentTree extends StatefulWidget {
  const _ContentTree({
    required this.rootFolderId,
    required this.folderAlbums,
    required this.folderState,
    required this.hiddenFolderIds,
    required this.selectedFolderIds,
    required this.selectedAlbumIds,
    required this.includeFolderItems,
    required this.onFolderToggle,
    required this.onAlbumToggle,
    required this.onLooseItemsToggle,
  });

  final String rootFolderId;
  final List<AlbumModel> folderAlbums;
  final FolderFacade folderState;
  final Set<String> hiddenFolderIds;
  final Set<String> selectedFolderIds;
  final Set<String> selectedAlbumIds;
  final bool includeFolderItems;
  final void Function(String id, bool checked) onFolderToggle;
  final void Function(String id, bool checked) onAlbumToggle;
  final ValueChanged<bool> onLooseItemsToggle;

  @override
  State<_ContentTree> createState() => _ContentTreeState();
}

class _ContentTreeState extends State<_ContentTree> {
  final Set<String> _expandedFolders = {};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Direct child sub-folders of root
    final directSubFolders = widget.folderState.folders
        .where((f) =>
            f.parentId == widget.rootFolderId &&
            f.deletedAt == null)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // Albums directly in root (no sub-folder wrapper)
    final rootAlbums = widget.folderAlbums
        .where((a) => a.folderId == widget.rootFolderId)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final hasSubFolders = directSubFolders.isNotEmpty;
    final hasAlbums = rootAlbums.isNotEmpty;
    final isEmpty = !hasSubFolders && !hasAlbums;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Loose items in root ─────────────────────────────────────────
        _SettingCard(
          child: CheckboxListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            value: widget.includeFolderItems,
            onChanged: (v) => widget.onLooseItemsToggle(v ?? false),
            secondary: Icon(Icons.photo_library_outlined,
                size: 18, color: AppColors.primary),
            title: const Text('Loose items directly in this folder',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              'Photos & videos not inside any album.',
              style: TextStyle(
                  fontSize: 12, color: cs.onSurface.withOpacity(0.55)),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),

        // ── Sub-folders ─────────────────────────────────────────────────
        if (hasSubFolders)
          _SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Text(
                    'Sub-folders (${directSubFolders.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.55)),
                  ),
                ),
                ...directSubFolders.asMap().entries.map((entry) {
                  final folder = entry.value;
                  final isHidden =
                      widget.hiddenFolderIds.contains(folder.id);
                  final isSelected =
                      widget.selectedFolderIds.contains(folder.id);
                  final isExpanded =
                      _expandedFolders.contains(folder.id);

                  // Albums inside this direct sub-folder
                  final subAlbums = widget.folderAlbums
                      .where((a) => a.folderId == folder.id)
                      .toList()
                    ..sort((a, b) => a.name.compareTo(b.name));

                  return Column(
                    children: [
                      if (entry.key > 0) const Divider(height: 1),
                      // Folder checkbox + expand toggle
                      InkWell(
                        onTap: subAlbums.isEmpty
                            ? null
                            : () => setState(() {
                                  if (isExpanded) {
                                    _expandedFolders.remove(folder.id);
                                  } else {
                                    _expandedFolders.add(folder.id);
                                  }
                                }),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
                          child: Row(
                            children: [
                              Checkbox(
                                value: isHidden ? false : isSelected,
                                onChanged: isHidden
                                    ? null
                                    : (v) => widget.onFolderToggle(
                                        folder.id, v ?? false),
                              ),
                              Icon(
                                isExpanded
                                    ? Icons.folder_open_rounded
                                    : Icons.folder_rounded,
                                size: 18,
                                color: isHidden
                                    ? cs.onSurface.withOpacity(0.3)
                                    : AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  folder.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: isHidden
                                        ? cs.onSurface.withOpacity(0.4)
                                        : null,
                                  ),
                                ),
                              ),
                              if (isHidden)
                                Icon(Icons.visibility_off_outlined,
                                    size: 14,
                                    color:
                                        cs.onSurface.withOpacity(0.3)),
                              const SizedBox(width: 4),
                              if (subAlbums.isNotEmpty)
                                Icon(
                                  isExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 18,
                                  color: cs.onSurface.withOpacity(0.4),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // Expanded album children
                      if (isExpanded)
                        ...subAlbums.asMap().entries.map((ae) {
                          final album = ae.value;
                          final albumHidden = widget.hiddenFolderIds
                              .contains(album.folderId);
                          final albumSelected =
                              widget.selectedAlbumIds.contains(album.id);
                          return Column(
                            children: [
                              const Divider(height: 1, indent: 52),
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 28),
                                child: CheckboxListTile(
                                  dense: true,
                                  value:
                                      albumHidden ? false : albumSelected,
                                  onChanged: albumHidden
                                      ? null
                                      : (v) => widget.onAlbumToggle(
                                          album.id, v ?? false),
                                  secondary: Icon(
                                    Icons.photo_album_outlined,
                                    size: 16,
                                    color: albumHidden
                                        ? cs.onSurface.withOpacity(0.3)
                                        : AppColors.primary,
                                  ),
                                  title: Text(
                                    album.name,
                                    style: TextStyle(
                                      color: albumHidden
                                          ? cs.onSurface.withOpacity(0.4)
                                          : null,
                                    ),
                                  ),
                                  subtitle: albumHidden
                                      ? Text('Hidden',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: cs.onSurface
                                                  .withOpacity(0.4)))
                                      : null,
                                ),
                              ),
                            ],
                          );
                        }),
                    ],
                  );
                }),
              ],
            ),
          ),
        if (hasSubFolders) const SizedBox(height: AppSpacing.sm),

        // ── Albums directly in root ─────────────────────────────────────
        if (hasAlbums)
          _SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Text(
                    'Albums directly here (${rootAlbums.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.55)),
                  ),
                ),
                ...rootAlbums.asMap().entries.map((ae) {
                  final album = ae.value;
                  final isHidden = widget.hiddenFolderIds
                      .contains(album.folderId);
                  final isSelected =
                      widget.selectedAlbumIds.contains(album.id);
                  return Column(
                    children: [
                      if (ae.key > 0) const Divider(height: 1),
                      CheckboxListTile(
                        dense: true,
                        value: isHidden ? false : isSelected,
                        onChanged: isHidden
                            ? null
                            : (v) =>
                                widget.onAlbumToggle(album.id, v ?? false),
                        secondary: Icon(
                          Icons.photo_album_outlined,
                          size: 16,
                          color: isHidden
                              ? cs.onSurface.withOpacity(0.3)
                              : AppColors.primary,
                        ),
                        title: Text(
                          album.name,
                          style: TextStyle(
                              color: isHidden
                                  ? cs.onSurface.withOpacity(0.4)
                                  : null),
                        ),
                        subtitle: isHidden
                            ? Text('Hidden',
                                style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        cs.onSurface.withOpacity(0.4)))
                            : null,
                      ),
                    ],
                  );
                }),
              ],
            ),
          ),

        // ── Empty state ─────────────────────────────────────────────────
        if (isEmpty)
          _SettingCard(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  Icon(Icons.folder_off_outlined,
                      size: 36,
                      color: cs.onSurface.withOpacity(0.3)),
                  const SizedBox(height: 8),
                  Text(
                    'No sub-folders or albums yet.\n'
                    'Enable "Loose items" above to share photos & videos '
                    'uploaded directly to this folder.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.5)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
