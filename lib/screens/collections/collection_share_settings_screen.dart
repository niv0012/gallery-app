import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/routes/app_routes.dart';
import '../../models/share_link_model.dart';
import '../../providers/auth_providers.dart';
import '../../models/studio_client_connection_model.dart';
import '../../providers/gallery_collections_provider.dart';
import '../../providers/share_link_provider.dart';
import '../../providers/studio_client_connections_provider.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../core/theme/theme_context.dart';

enum ShareMode { public, client, private }

class CollectionShareSettingsScreen extends ConsumerStatefulWidget {
  final String collectionId;

  const CollectionShareSettingsScreen({super.key, required this.collectionId});

  @override
  ConsumerState<CollectionShareSettingsScreen> createState() =>
      _CollectionShareSettingsScreenState();
}

class _CollectionShareSettingsScreenState extends ConsumerState<CollectionShareSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();

  bool _initialized = false;
  ShareMode _shareMode = ShareMode.public;
  String? _selectedClientId;
  bool _hasExpiry = false;
  DateTime? _expiryDate;
  bool _allowDownload = true;
  bool _showWatermark = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _generateRandomPasscode() {
    final rand = Random.secure();
    final passcode = (100000 + rand.nextInt(900000)).toString();
    setState(() {
      _passwordController.text = passcode;
    });
  }

  /// Primes the form from the loaded link, once.
  void _initFields(GalleryShareLink? link) {
    if (_initialized) return;
    _initialized = true;

    if (link != null && !link.isRevoked) {
      if (link.hasPassword) {
        _shareMode = ShareMode.private;
      } else if (link.clientId != null) {
        _shareMode = ShareMode.client;
      } else {
        _shareMode = ShareMode.public;
      }
      _selectedClientId = link.clientId;
      _hasExpiry = link.expiresAt != null;
      _expiryDate = link.expiresAt;
      _allowDownload = link.allowDownload;
      _showWatermark = link.showWatermark;
    }
  }

  Future<void> _selectExpiryDate(BuildContext context) async {
    final now = DateTime.now();
    final initialDate = _expiryDate ?? now.add(const Duration(days: 7));
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate.isBefore(now) ? now : initialDate,
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

  /// Returns true when [widget.collectionId] is a real server-side UUID (e.g.
  /// `3fa85f64-5717-4562-b3fc-2c963f66afa6`) rather than a local placeholder
  /// the old in-memory / Hive-only implementation stamped on new albums
  /// (e.g. `al-<microseconds>`). Only backend-synced albums can have share
  /// links — the server-side `POST /share-links` will always 404 for a
  /// placeholder id because no matching row exists in the database.
  bool get _isBackendSynced {
    // UUIDs are exactly 36 chars: 8-4-4-4-12 hex digits + 4 hyphens.
    final id = widget.collectionId;
    if (id.length != 36) return false;
    // Quick regex check — avoids depending on a UUID package.
    return RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            caseSensitive: false)
        .hasMatch(id);
  }

  Future<void> _saveSettings(GalleryShareLink? existingLink) async {
    final hasExistingPassword = existingLink != null &&
        !existingLink.isRevoked &&
        existingLink.hasPassword;

    if (_shareMode == ShareMode.private &&
        !hasExistingPassword &&
        !_formKey.currentState!.validate()) {
      return;
    }
    if (_shareMode == ShareMode.private &&
        hasExistingPassword &&
        _passwordController.text.isNotEmpty) {
      if (!_formKey.currentState!.validate()) return;
    }
    if (_shareMode == ShareMode.client && _selectedClientId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a client.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      if (!_isBackendSynced) {
        // This album was created while the app was running in offline /
        // demo mode and never synced to the server. Share links require a
        // real backend album. Ask the user to re-create the album.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This album was created in offline mode and cannot be shared yet. '
              'Please delete it and recreate it while connected to sync it to the server.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
        return;
      }

      final controller =
          ref.read(shareLinkControllerProvider(ShareTarget(collectionId: widget.collectionId)).notifier);
      await controller.createOrUpdate(
        clientId: _shareMode == ShareMode.client ? _selectedClientId : null,
        clearClient: _shareMode != ShareMode.client,
        password: _shareMode == ShareMode.private
            ? (_passwordController.text.isEmpty
                ? null
                : _passwordController.text)
            : null,
        clearPassword: _shareMode != ShareMode.private,
        expiresAt: _hasExpiry ? _expiryDate : null,
        clearExpiry: !_hasExpiry,
        allowDownload: _allowDownload,
        showWatermark: _showWatermark,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Share settings updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't update share settings: $e")),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _revokeLink() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revoke Share Link?'),
        content: Text(
          'This will immediately make the link inactive. Clients will no longer be able to access the gallery.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(shareLinkControllerProvider(ShareTarget(collectionId: widget.collectionId)).notifier)
          .revoke();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Share link revoked.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't revoke link: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final collections = ref.watch(galleryCollectionsProvider).collections;
    final collection = collections.firstWhere((a) => a.id == widget.collectionId);

    final linkState = ref.watch(shareLinkControllerProvider(ShareTarget(collectionId: widget.collectionId)));
    final activeLink = linkState.activeLink;
    final hasActiveLink = activeLink != null && !activeLink.isRevoked;

    _initFields(activeLink);

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Share "${collection.name}"',
        showBack: true,
      ),
      body: SafeArea(
        child: linkState.isLoading && activeLink == null
            ? Center(child: CircularProgressIndicator(color: AppColors.primary))
            : LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!_isBackendSynced) ...[
                                Container(
                                  padding: EdgeInsets.all(AppSpacing.md),
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.orange.withValues(alpha: 0.12),
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.md),
                                    border: Border.all(
                                        color: Colors.orange
                                            .withValues(alpha: 0.4)),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.cloud_off_rounded,
                                          color: Colors.orange, size: 20),
                                      SizedBox(width: AppSpacing.sm),
                                      Expanded(
                                        child: Text(
                                          'This album was created offline and hasn\'t been synced to the server. '
                                          'Delete it and recreate it while connected to enable sharing.',
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.orange,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: AppSpacing.lg),
                              ],
                              _buildSectionHeader(context, 'Gallery Type'),
                              SizedBox(height: AppSpacing.sm),
                              _buildGalleryTypeSelector(context),
                              SizedBox(height: AppSpacing.lg),
                              if (_shareMode == ShareMode.private) ...[
                                _buildSectionHeader(
                                    context, 'Security Settings'),
                                SizedBox(height: AppSpacing.sm),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: CustomTextField(
                                        label: hasActiveLink &&
                                                activeLink.hasPassword
                                            ? 'New Passcode (leave blank to keep current)'
                                            : 'Passcode',
                                        icon: Icons.lock_outline_rounded,
                                        controller: _passwordController,
                                        obscureText: false,
                                        validator: (v) {
                                          if (hasActiveLink &&
                                              activeLink.hasPassword &&
                                              (v == null || v.isEmpty)) {
                                            return null;
                                          }
                                          if (v == null ||
                                              v.trim().length < 4) {
                                            return 'Passcode must be at least 4 characters';
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    SizedBox(width: AppSpacing.sm),
                                    Padding(
                                      padding: EdgeInsets.only(top: 4),
                                      child: OutlinedButton.icon(
                                        onPressed: _generateRandomPasscode,
                                        icon: Icon(Icons.refresh_rounded,
                                            size: 16),
                                        label: Text('Regenerate'),
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: AppSpacing.lg),
                              ],
                              _buildSectionHeader(
                                  context, 'Link Configuration'),
                              SizedBox(height: AppSpacing.sm),
                              _buildLinkSettingsCard(),
                              SizedBox(height: AppSpacing.xl),
                              GradientButton(
                                label: hasActiveLink
                                    ? 'Update Settings'
                                    : 'Generate Share Link',
                                isLoading: _isSaving,
                                onPressed: (_isSaving || !_isBackendSynced)
                                    ? null
                                    : () => _saveSettings(activeLink),
                              ),
                              if (hasActiveLink) ...[
                                SizedBox(height: AppSpacing.xxl),
                                Divider(color: context.borderColor),
                                SizedBox(height: AppSpacing.lg),
                                _buildSectionHeader(
                                    context, 'Active Share Link'),
                                SizedBox(height: AppSpacing.sm),
                                _buildActiveLinkCard(activeLink),
                                SizedBox(height: AppSpacing.xl),
                                _buildSectionHeader(
                                    context, 'Link Analytics & QR'),
                                SizedBox(height: AppSpacing.sm),
                                _buildAnalyticsAndQrCard(activeLink),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: TextStyle(
        fontSize: 14.5,
        fontWeight: FontWeight.w800,
        color: isDark ? AppColors.textOnDark : AppColors.text,
      ),
    );
  }

  Widget _buildGalleryTypeSelector(BuildContext context) {
    final authState = ref.watch(authProvider);
    final studioId = authState.valueOrNull?.id ?? '';
    final connections = ref.watch(connectionsProvider);
    final connectedClients = connections.valueOrNull
            ?.where((c) =>
                c.studioId == studioId &&
                c.status == ConnectionStatus.connected)
            .toList() ??
        [];

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          RadioListTile<ShareMode>(
            value: ShareMode.public,
            groupValue: _shareMode,
            title: Text(
              'Public Gallery',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Anyone with the link can view and browse the photos.',
              style: TextStyle(
                  fontSize: 12,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeColor: AppColors.primary,
            onChanged: (val) {
              if (val != null) setState(() => _shareMode = val);
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          RadioListTile<ShareMode>(
            value: ShareMode.client,
            groupValue: _shareMode,
            title: Text(
              'Specific Client',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Assign directly to a connected client\'s account.',
              style: TextStyle(
                  fontSize: 12,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeColor: AppColors.primary,
            onChanged: (val) {
              if (val != null) setState(() => _shareMode = val);
            },
          ),
          if (_shareMode == ShareMode.client)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: 'Select Client',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                value: _selectedClientId,
                items: connectedClients.map((c) {
                  return DropdownMenuItem(
                    value: c.clientId,
                    child: Text(c.clientData?.name ?? 'Unknown Client'),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() => _selectedClientId = val);
                },
              ),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          RadioListTile<ShareMode>(
            value: ShareMode.private,
            groupValue: _shareMode,
            title: Text(
              'Private Gallery',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Requires entering a passcode to validate access.',
              style: TextStyle(
                  fontSize: 12,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeColor: AppColors.primary,
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _shareMode = val;
                  if (_shareMode == ShareMode.private &&
                      _passwordController.text.isEmpty) {
                    _generateRandomPasscode();
                  }
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLinkSettingsCard() {
    return Container(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          SwitchListTile(
            value: _hasExpiry,
            title: Text(
              'Set Expiry Date',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Link will automatically expire after the date.',
              style: TextStyle(
                  fontSize: 11.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeThumbColor: AppColors.primary,
            onChanged: (val) {
              setState(() {
                _hasExpiry = val;
                if (val && _expiryDate == null) {
                  _expiryDate = DateTime.now().add(const Duration(days: 7));
                }
              });
            },
          ),
          if (_hasExpiry)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 16,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle)),
                  SizedBox(width: 8),
                  Text(
                    _expiryDate == null
                        ? 'No date selected'
                        : '${_expiryDate!.day}/${_expiryDate!.month}/${_expiryDate!.year}',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text)),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _selectExpiryDate(context),
                    child: Text('Change Date'),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            value: _allowDownload,
            title: Text(
              'Allow Downloads',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Clients can download high-res original photos.',
              style: TextStyle(
                  fontSize: 11.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeThumbColor: AppColors.primary,
            onChanged: (val) => setState(() => _allowDownload = val),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            value: _showWatermark,
            title: Text(
              'Overlay Watermark',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
            ),
            subtitle: Text(
              'Display a soft "picgallery" brand watermarking over photos.',
              style: TextStyle(
                  fontSize: 11.5,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            activeThumbColor: AppColors.primary,
            onChanged: (val) => setState(() => _showWatermark = val),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveLinkCard(GalleryShareLink link) {
    final primaryUrl = link.primaryShareUrl;
    debugPrint('[SHARE_DEBUG] Original shareId (token): ${link.token}');
    debugPrint('[SHARE_DEBUG] Generated share URL: $primaryUrl');
    debugPrint('[SHARE_DEBUG] QR encoded URL: $primaryUrl');

    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  primaryUrl,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy_rounded, color: AppColors.primary),
                tooltip: 'Copy Link',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: primaryUrl));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('HTTPS Share Link copied to clipboard.')),
                  );
                },
              ),
              IconButton(
                icon: Icon(Icons.share_rounded, color: AppColors.primary),
                tooltip: 'Share',
                onPressed: () {
                  SharePlus.instance.share(
                    ShareParams(
                      text: primaryUrl,
                      subject: 'Check out this shared gallery!',
                    ),
                  );
                },
              ),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushNamed(
                      AppRoutes.sharedGallery,
                      arguments:
                          SharedGalleryArgs(token: link.token, isPreview: true),
                    );
                  },
                  icon: Icon(Icons.remove_red_eye_outlined),
                  label: Text('Preview Client View'),
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                  ),
                  onPressed: _revokeLink,
                  icon: Icon(Icons.link_off_rounded),
                  label: Text('Revoke Link'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsAndQrCard(GalleryShareLink link) {
    final statusColor = link.isExpired
        ? Colors.orange
        : (link.isRevoked ? AppColors.error : AppColors.success);
    final statusText =
        link.isExpired ? 'Expired' : (link.isRevoked ? 'Revoked' : 'Active');

    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Link Analytics',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text)),
                ),
                SizedBox(height: AppSpacing.md),
                _buildAnalyticRow(
                    Icons.info_outline_rounded, 'Status', statusText,
                    valueColor: statusColor),
                _buildAnalyticRow(Icons.visibility_outlined, 'Total Views',
                    '${link.viewsCount}'),
                _buildAnalyticRow(Icons.download_outlined, 'Downloads',
                    '${link.downloadsCount}'),
                _buildAnalyticRow(Icons.lock_clock_outlined, 'Type',
                    link.hasPassword ? 'Private (Protected)' : 'Public'),
              ],
            ),
          ),
          SizedBox(width: AppSpacing.md),
          Column(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white, // QR needs a white quiet zone
                  border: Border.all(color: context.borderColor),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: QrImageView(
                  // Encodes the HTTPS universal link: works in camera scanner apps,
                  // opens native App directly via App Links / Universal Links, or
                  // falls back to browser Web Client Gallery when app is not installed.
                  data: link.primaryShareUrl,
                  version: QrVersions.auto,
                  size: 110.0,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Scan QR to Share',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticRow(IconData icon, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon,
              size: 16,
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle)),
          SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.subtitleOnDark
                    : AppColors.subtitle)),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: valueColor ??
                  (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}
