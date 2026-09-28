import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/routes/app_routes.dart';
import '../../models/media_model.dart';
import '../../models/share_link_model.dart';
import '../../providers/face_search_provider.dart';
import '../../providers/share_link_provider.dart';
import '../media/image_viewer_screen.dart';
import '../media/video_player_screen.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/cards/glass_card.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/pinch_zoom_handler.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../services/share_service_impl.dart';
import '../../services/download_service_impl.dart';
import '../../services/media_file_cache.dart';
import '../../widgets/media/watermark_overlay.dart';
import '../../providers/auth_providers.dart'
    show apiClientProvider;
import '../../providers/settings_provider.dart';
import '../../core/theme/theme_context.dart';

const _gridFileCache = MediaFileCache();
const _gridDownloadService = DownloadServiceImpl();
const _gridShareService = ShareServiceImpl();

Future<void> _shareMultipleMedia(
  BuildContext context,
  List<MediaModel> mediaList, {
  String? watermarkUrl,
}) async {
  if (kIsWeb) {
    final bytesList = <Uint8List>[];
    final fileNames = <String>[];
    for (final m in mediaList) {
      final result =
          await _gridFileCache.bytesFor(m, watermarkUrl: watermarkUrl);
      if (result != null) {
        bytesList.add(result.bytes);
        fileNames.add(result.fileName);
      }
    }
    if (bytesList.isEmpty || !context.mounted) return;
    await _gridShareService.shareMultipleMediaBytes(
      context: context,
      bytesList: bytesList,
      fileNames: fileNames,
    );
    return;
  }

  final paths = <String>[];
  for (final m in mediaList) {
    final path =
        await _gridFileCache.localPathFor(m, watermarkUrl: watermarkUrl);
    if (path != null) paths.add(path);
  }
  if (paths.isEmpty || !context.mounted) return;
  await _gridShareService.shareMultipleMedia(
    context: context,
    filePaths: paths,
  );
}

/// A guest's view of a shared album — reached either via a
/// `picgallery://shared/{token}` deep link (real client scanning the
/// studio's QR/link) or "Preview Client View" from `ShareSettingsScreen`.
///
/// Unlike the old version of this screen, [token] resolves against the
/// real public `/public/share-links/{token}` API
/// (`PublicGalleryController`) — no account, no auth, and no dependency
/// on `albumProvider`/`mediaProvider` (which only ever hold the
/// *current* user's own owner-scoped data and would be empty or 403 for
/// an unauthenticated guest, or for a client viewing a studio they
/// don't own).
class SharedGalleryScreen extends ConsumerStatefulWidget {
  final String token;
  final bool isPreview;

  const SharedGalleryScreen({
    super.key,
    required this.token,
    this.isPreview = false,
    this.albumId,
  });

  final String? albumId;

  @override
  ConsumerState<SharedGalleryScreen> createState() =>
      _SharedGalleryScreenState();
}

enum _ClientGalleryViewMode { compactGrid, grid, list, details }

class _SharedGalleryScreenState extends ConsumerState<SharedGalleryScreen> {
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final bool _obscurePasscode = true;
  final Set<String> _selectedIds = {};

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  _ClientGalleryViewMode _viewMode = _ClientGalleryViewMode.grid;

  // GestureDetector-based scale tracking – works for both touch pinch
  // and trackpad pinch-to-zoom on Flutter Web.
  double _scaleStartModeIndex = 3.0;

  int get _currentModeIndex {
    switch (_viewMode) {
      case _ClientGalleryViewMode.compactGrid: return 4;
      case _ClientGalleryViewMode.grid: return 3;
      case _ClientGalleryViewMode.list: return 2;
      case _ClientGalleryViewMode.details: return 1;
    }
  }


  void _changeViewMode(_ClientGalleryViewMode mode) {
    setState(() => _viewMode = mode);
    final settings = ref.read(settingsProvider);
    String modeStr = 'Grid';
    if (mode == _ClientGalleryViewMode.compactGrid) modeStr = 'Compact';
    if (mode == _ClientGalleryViewMode.list) modeStr = 'List';
    if (mode == _ClientGalleryViewMode.details) modeStr = 'Details';
    ref.read(settingsProvider.notifier).updateSettings(settings.copyWith(galleryViewMode: modeStr));
  }

  void _zoomIn() {
    switch (_viewMode) {
      case _ClientGalleryViewMode.compactGrid:
        _changeViewMode(_ClientGalleryViewMode.grid);
        break;
      case _ClientGalleryViewMode.grid:
        _changeViewMode(_ClientGalleryViewMode.list);
        break;
      case _ClientGalleryViewMode.list:
        _changeViewMode(_ClientGalleryViewMode.details);
        break;
      case _ClientGalleryViewMode.details:
        break;
    }
  }

  void _zoomOut() {
    switch (_viewMode) {
      case _ClientGalleryViewMode.details:
        _changeViewMode(_ClientGalleryViewMode.list);
        break;
      case _ClientGalleryViewMode.list:
        _changeViewMode(_ClientGalleryViewMode.grid);
        break;
      case _ClientGalleryViewMode.grid:
        _changeViewMode(_ClientGalleryViewMode.compactGrid);
        break;
      case _ClientGalleryViewMode.compactGrid:
        break;
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = ref.read(settingsProvider);
      if (settings.galleryViewMode == 'List') {
        setState(() => _viewMode = _ClientGalleryViewMode.list);
      } else if (settings.galleryViewMode == 'Compact') {
        setState(() => _viewMode = _ClientGalleryViewMode.compactGrid);
      } else if (settings.galleryViewMode == 'Details') {
        setState(() => _viewMode = _ClientGalleryViewMode.details);
      } else {
        setState(() => _viewMode = _ClientGalleryViewMode.grid);
      }
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submitPasscode() {
    if (!_formKey.currentState!.validate()) return;
    ref
        .read(publicGalleryControllerProvider(PublicGalleryTarget(token: widget.token, albumId: widget.albumId)).notifier)
        .unlock(password: _passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(publicGalleryControllerProvider(PublicGalleryTarget(token: widget.token, albumId: widget.albumId)));

    switch (controller.status) {
      case PublicGalleryStatus.loading:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
              child: CircularProgressIndicator(color: AppColors.primary)),
        );

      case PublicGalleryStatus.notFound:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.search_off_rounded,
              message: 'This shared link does not exist.',
            ),
          ),
        );

      case PublicGalleryStatus.revoked:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.link_off_rounded,
              message: 'This shared link has been revoked by the photographer.',
            ),
          ),
        );

      case PublicGalleryStatus.albumDeleted:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.folder_off_rounded,
              message: 'This album has been deleted by the photographer.',
            ),
          ),
        );
      case PublicGalleryStatus.expired:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.lock_clock_outlined,
              message: 'This shared link has expired.',
            ),
          ),
        );

      case PublicGalleryStatus.unauthorized:
        return const Scaffold(
          appBar: CustomAppBar(title: 'Private Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.gavel_rounded,
              message: 'You are not authorized to access this private gallery.',
            ),
          ),
        );
      case PublicGalleryStatus.error:
        return Scaffold(
          appBar: const CustomAppBar(title: 'Shared Gallery', showBack: true),
          body: Center(
            child: EmptyStateCard(
              icon: Icons.wifi_off_rounded,
              message: controller.errorMessage ??
                  "Couldn't reach the server. Check your connection and try again.",
            ),
          ),
        );

      case PublicGalleryStatus.needsPassword:
      case PublicGalleryStatus.wrongPassword:
      case PublicGalleryStatus.downloadsDisabled:
        return _buildPasscodeGate(context, controller);

      case PublicGalleryStatus.loaded:
        return _buildGallery(context, controller.data!, controller);
    }
  }

  Widget _buildPreviewBanner() {
    if (!widget.isPreview) return SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.amber.shade800,
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.remove_red_eye_rounded, color: Colors.white, size: 16),
          SizedBox(width: 8),
          Text(
            'PREVIEW MODE — Client Gallery View',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // PRIVATE GALLERY ACCESS SCREEN (Passcode Gate)
  // -------------------------------------------------------------
  Widget _buildPasscodeGate(
      BuildContext context, PublicGalleryController controller) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Private Access',
            style: TextStyle(
                color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                fontSize: 16,
                fontWeight: FontWeight.w800)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildPreviewBanner(),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: GlassCard(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      borderRadius: AppRadius.lg,
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.lock_person_rounded,
                                    color: AppColors.primary, size: 20),
                                SizedBox(width: 10),
                                Text(
                                  'Password Protected',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                              ],
                            ),
                            SizedBox(height: 8),
                            Text(
                              'This gallery contains private content. Enter the passcode to continue.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                                  height: 1.4),
                            ),
                            SizedBox(height: AppSpacing.md),
                            Text(
                              'Passcode',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text)),
                            ),
                            SizedBox(height: 6),
                            CustomTextField(
                              label: 'Enter Passcode',
                              icon: Icons.key_rounded,
                              controller: _passwordController,
                              obscureText: _obscurePasscode,
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return 'Enter passcode';
                                }
                                return null;
                              },
                            ),
                            if (controller.status ==
                                PublicGalleryStatus.wrongPassword) ...[
                              SizedBox(height: AppSpacing.sm),
                              Text(
                                'Incorrect passcode. Please try again.',
                                style: TextStyle(
                                    color: AppColors.error,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                            ],
                            SizedBox(height: AppSpacing.lg),
                            GradientButton(
                              label: 'Unlock & View Gallery',
                              onPressed: _submitPasscode,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // PUBLIC OR UNLOCKED GALLERY SCREEN (Parallax Cover, Info, Grid)
  // -------------------------------------------------------------
  Widget _buildGallery(BuildContext context, PublicGalleryData data,
      PublicGalleryController controller) {
    final albumMedia = List<MediaModel>.from(data.media ?? [])
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final hasCover = albumMedia.isNotEmpty;
    final coverMedia = hasCover ? albumMedia.first : null;

    return Scaffold(
      body: PinchZoomHandler(
        onZoomIn: _zoomIn,
        onZoomOut: _zoomOut,
        child: GestureDetector(
        // GestureDetector onScaleUpdate handles BOTH two-finger touch pinch
        // AND trackpad pinch-to-zoom on Flutter Web natively.
        onScaleStart: (_) {
          _scaleStartModeIndex = _currentModeIndex.toDouble();
        },
        onScaleUpdate: (details) {
          if (details.scale == 1.0) return;
          final newLevel = (_scaleStartModeIndex / details.scale).round().clamp(1, 4);
          if (newLevel != _currentModeIndex) {
            if (newLevel == 4) {
              _changeViewMode(_ClientGalleryViewMode.compactGrid);
            } else if (newLevel == 3) {
              _changeViewMode(_ClientGalleryViewMode.grid);
            } else if (newLevel == 2) {
              _changeViewMode(_ClientGalleryViewMode.list);
            } else if (newLevel == 1) {
              _changeViewMode(_ClientGalleryViewMode.details);
            }
          }
        },
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              elevation: 0,
              leadingWidth: 64,
            leading: Padding(
              padding: EdgeInsets.only(left: 12),
              child: Center(
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(100),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                    ),
                    child: Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
            actions: [
              if (_isSelectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (_selectedIds.length == albumMedia.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds.addAll(albumMedia.map((m) => m.id));
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(100),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        child: Icon(
                          _selectedIds.length == albumMedia.length ? Icons.deselect_rounded : Icons.select_all_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              if (kIsWeb)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.4),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      icon: Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text('Open in App', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      onPressed: () async {
                        final uri = Uri.parse('picgallery://shared/${widget.token}');
                        final playStoreUri = Uri.parse('https://play.google.com/store/apps/details?id=com.mk.picgallery');
                        try {
                          if (!await launchUrl(uri)) {
                            // If custom scheme fails (app not installed), redirect to Play Store
                            await launchUrl(playStoreUri, mode: LaunchMode.externalApplication);
                          }
                        } catch (e) {
                          // Catch any platform exception and redirect to Play Store
                          await launchUrl(playStoreUri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                  ),
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                data.album?.name ?? data.collection?.name ?? 'Gallery',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  shadows: [
                    Shadow(
                        color: Colors.black54,
                        blurRadius: 4,
                        offset: Offset(0, 2))
                  ],
                ),
              ),
              centerTitle: true,
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCoverImage(coverMedia, data.album?.gradientArgb ?? const [0xFF7C5CFF, 0xFFA855F7, 0xFFEC4899]),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black38, Colors.black87],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isPreview) ...[
                    _buildPreviewBanner(),
                    SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: data.requiresPassword
                              ? Colors.purple.withValues(alpha: 0.12)
                              : Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: data.requiresPassword
                                ? Colors.purple.withValues(alpha: 0.3)
                                : Colors.blue.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                                data.requiresPassword
                                    ? Icons.lock_open_rounded
                                    : Icons.public_rounded,
                                size: 12,
                                color: data.requiresPassword
                                    ? Colors.purple
                                    : Colors.blue),
                            SizedBox(width: 4),
                            Text(
                              data.requiresPassword
                                  ? 'Private Unlocked'
                                  : 'Public Gallery',
                              style: TextStyle(
                                  color: data.requiresPassword
                                      ? Colors.purple
                                      : Colors.blue,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          (data.albums != null && data.albums!.isNotEmpty)
                              ? '${data.albums!.length} Albums'
                              : '${albumMedia.length} Photos & Videos',
                          style: TextStyle(
                              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<_ClientGalleryViewMode>(
                        tooltip: 'Change View Mode',
                        initialValue: _viewMode,
                        onSelected: _changeViewMode,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _viewMode == _ClientGalleryViewMode.compactGrid
                                    ? Icons.apps_rounded
                                    : _viewMode == _ClientGalleryViewMode.grid
                                        ? Icons.grid_view_rounded
                                        : _viewMode == _ClientGalleryViewMode.list
                                            ? Icons.view_list_rounded
                                            : Icons.table_rows_rounded,
                                size: 16,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.textOnDark
                                    : AppColors.text,
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_drop_down,
                                  size: 16,
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                            ],
                          ),
                        ),
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.compactGrid,
                            child: Text('Compact Grid'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.grid,
                            child: Text('Grid'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.list,
                            child: Text('List'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.details,
                            child: Text('Details'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    (data.albums != null && data.albums!.isNotEmpty)
                        ? 'Welcome to your collection. Tap any album to view its gallery.'
                        : 'Welcome to your proofing gallery. Tap any image to review details, zoom, or playback video.',
                    style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle), fontSize: 12, height: 1.4),
                  ),
                  SizedBox(height: 12),
                  Divider(color: context.borderColor),
                ],
              ),
            ),
          ),
          (data.albums != null && data.albums!.isNotEmpty)
              ? ((_viewMode == _ClientGalleryViewMode.list || _viewMode == _ClientGalleryViewMode.details)
                  ? SliverPadding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final a = data.albums![i];
                            return Container(
                              margin: EdgeInsets.only(bottom: 12),
                              height: _viewMode == _ClientGalleryViewMode.details ? 300 : 200,
                              child: _buildAlbumGridItem(context, a, widget.token, widget.isPreview),
                            );
                          },
                          childCount: data.albums!.length,
                        ),
                      ),
                    )
                  : SliverPadding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: MediaQuery.of(context).size.width < 420
                              ? (_viewMode == _ClientGalleryViewMode.compactGrid ? 8 : 2)
                              : (MediaQuery.of(context).size.width ~/ (_viewMode == _ClientGalleryViewMode.compactGrid ? 50 : 140)).clamp(2, 12),
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.8,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final a = data.albums![i];
                            return _buildAlbumGridItem(context, a, widget.token, widget.isPreview);
                          },
                          childCount: data.albums!.length,
                        ),
                      ),
                    ))
              : (data.collection != null)
                  ? const SliverFillRemaining(
                      child: Center(
                        child: EmptyStateCard(
                          icon: Icons.photo_album_outlined,
                          message: 'This collection contains no albums.',
                        ),
                      ),
                    )
                  : albumMedia.isEmpty
                      ? const SliverFillRemaining(
                          child: Center(
                            child: EmptyStateCard(
                              icon: Icons.photo_library_outlined,
                              message: 'This shared gallery contains no photos.',
                            ),
                          ),
                        )
                      : (_viewMode == _ClientGalleryViewMode.list || _viewMode == _ClientGalleryViewMode.details)
                          ? SliverPadding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) {
                                    final m = albumMedia[i];
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                      child: SizedBox(
                                        height: _viewMode == _ClientGalleryViewMode.details ? 300 : 150,
                                        child: _buildGridItem(
                                            context, m, albumMedia, data.showWatermark, data.allowDownload, data.studioLogoUrl),
                                      ),
                                    );
                                  },
                                  childCount: albumMedia.length,
                                ),
                              ),
                            )
                          : SliverPadding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: MediaQuery.of(context).size.width < 420
                                      ? (_viewMode == _ClientGalleryViewMode.compactGrid ? 8 : 2)
                                      : (MediaQuery.of(context).size.width ~/ (_viewMode == _ClientGalleryViewMode.compactGrid ? 50 : 140)).clamp(2, 12),
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  childAspectRatio: 1.0,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) {
                                    final m = albumMedia[i];
                                    return _buildGridItem(context, m, albumMedia,
                                        data.showWatermark, data.allowDownload, data.studioLogoUrl);
                                  },
                                  childCount: albumMedia.length,
                                ),
                              ),
                            ),
        ],
      ), // closes CustomScrollView
      ), // closes GestureDetector
      ), // closes PinchZoomHandler
      floatingActionButton: _isSelectionMode
          ? Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (data.allowDownload)
                  FloatingActionButton.extended(
                    heroTag: 'share_fab',
                    onPressed: () async {
                      final ids = _selectedIds.toList(growable: false);
                      _clearSelection();
                      if (ids.isEmpty) return;

                      final itemsToShare = <MediaModel>[];
                      for (final id in ids) {
                        final m = albumMedia.firstWhere((x) => x.id == id,
                            orElse: () => albumMedia.first);
                        if (m.id == id && m.displayPath.trim().isNotEmpty) {
                          itemsToShare.add(m);
                        }
                      }
                      if (itemsToShare.isEmpty || !context.mounted) return;
                      await _shareMultipleMedia(
                        context,
                        itemsToShare,
                        watermarkUrl:
                            data.showWatermark ? data.studioLogoUrl : null,
                      );
                    },
                    icon: Icon(Icons.share_rounded),
                    label: Text('Share ${_selectedIds.length} items'),
                    backgroundColor: AppColors.primary,
                  ),
                if (data.allowDownload) ...[
                  SizedBox(width: 16),
                  FloatingActionButton.extended(
                    heroTag: 'download_fab',
                    onPressed: () async {
                      final ids = _selectedIds.toList(growable: false);
                      _clearSelection();
                      if (ids.isEmpty) return;

                      // For web/mobile downloading, loop through ids and download individually.
                      final apiClient = ref.read(apiClientProvider);
                      for (final id in ids) {
                        final m = albumMedia.firstWhere((x) => x.id == id,
                            orElse: () => albumMedia.first);
                        if (m.id != id) continue; // Not found

                        if (kIsWeb) {
                          final result = await _gridFileCache.bytesFor(
                            m,
                            watermarkUrl:
                                data.showWatermark ? data.studioLogoUrl : null,
                          );
                          if (result == null) continue;
                          if (!context.mounted) continue;
                          await _gridDownloadService.downloadBytes(
                            context: context,
                            bytes: result.bytes,
                            fileName: result.fileName,
                            mediaId: m.id,
                            apiClient: apiClient,
                            isClientUser: true,
                          );
                        } else {
                          final filePath = await _gridFileCache.localPathFor(
                            m,
                            watermarkUrl:
                                data.showWatermark ? data.studioLogoUrl : null,
                          );
                          if (filePath == null) continue;
                          if (!context.mounted) continue;
                          await _gridDownloadService.downloadOriginal(
                            context: context,
                            filePath: filePath,
                            mediaId: m.id,
                            apiClient: apiClient,
                            isClientUser: true,
                          );
                        }
                      }
                    },
                    icon: Icon(Icons.download_rounded),
                    label: Text('Download ${_selectedIds.length} items'),
                    backgroundColor: AppColors.primary,
                  ),
                ],
              ],
            )
          : (albumMedia.isNotEmpty
              ? FloatingActionButton.extended(
                  heroTag: 'shared_gallery_face_search_fab',
                  onPressed: () {
                    // Scopes the search to this one shared album via the
                    // token (+ whatever password already unlocked it, so
                    // the password-gated `/public/share-links/{token}/face-search`
                    // call doesn't re-prompt a guest who already got past
                    // the passcode gate above).
                    ref.read(faceSearchProvider.notifier).useSharedGallery(
                          token: widget.token,
                          password: controller.password,
                        );
                    Navigator.of(context)
                        .pushNamed(AppRoutes.faceSearchLanding);
                  },
                  icon: Icon(Icons.face_retouching_natural_rounded),
                  label: Text('Find My Photos'),
                  backgroundColor: AppColors.primary,
                )
              : null),
    );
  }

  Widget _buildCoverImage(MediaModel? media, List<int> fallbackGradient) {
    if (media == null) {
      final colors = fallbackGradient.length >= 2 
          ? fallbackGradient.map((c) => Color(c)).toList()
          : const [Color(0xFF2C3E50), Color(0xFF000000)];
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Icon(Icons.photo_library_rounded,
              color: Colors.white24, size: 48),
        ),
      );
    }
    final path = media.displayPath;
    final isNetwork = media.isDisplayPathNetwork;
    if (path.isNotEmpty) {
      if (isNetwork) {
        return Image.network(
          path,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(media.gradientArgb.first),
                  Color(media.gradientArgb[1])
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        );
      }
      final file = File(path);
      if (file.existsSync()) {
        return Image.file(file, fit: BoxFit.cover);
      }
    }
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(fallbackGradient.first),
            Color(fallbackGradient.length > 1
                ? fallbackGradient[1]
                : fallbackGradient.first)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }

  Widget _gridPlaceholder(MediaModel m) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(m.gradientArgb.first),
            Color(m.gradientArgb[1]),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          m.type == MediaType.photo
              ? Icons.image_rounded
              : Icons.play_arrow_rounded,
          color: Colors.white60,
        ),
      ),
    );
  }

  Widget _buildAlbumGridItem(BuildContext context, PublicAlbumSummary album, String token, bool isPreview) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).pushNamed(
          AppRoutes.sharedGallery,
          arguments: SharedGalleryArgs(
            token: token,
            isPreview: isPreview,
            albumId: album.id,
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          gradient: LinearGradient(
            colors: album.gradientArgb.map((c) => Color(c)).toList(),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.photo_album_rounded, color: Colors.white, size: 24),
              SizedBox(height: 8),
              Text(
                album.name,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridItem(BuildContext context, MediaModel m,
      List<MediaModel> allMedia, bool showWatermark, bool allowDownload, String? watermarkUrl) {
    final thumbPath = m.displayThumbnailPath;
    final isNetwork =
        thumbPath.startsWith('http://') || thumbPath.startsWith('https://');
    final file = (!isNetwork && thumbPath.isNotEmpty) ? File(thumbPath) : null;
    final hasRealFile = isNetwork || (!kIsWeb && file != null && file.existsSync());

    Widget imageWidget;
    if (isNetwork) {
      imageWidget = Image.network(
        thumbPath,
        fit: BoxFit.cover,
        cacheWidth: 300,
        errorBuilder: (_, __, ___) => _gridPlaceholder(m),
      );
    } else if (hasRealFile) {
      imageWidget = Image.file(
        file!,
        fit: BoxFit.cover,
        cacheWidth: 300,
      );
    } else {
      imageWidget = _gridPlaceholder(m);
    }

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(m.id);
          return;
        }
        // mediaItems is passed explicitly (rather than relying on
        // mediaProvider) because this media belongs to a studio the
        // guest doesn't own/isn't signed in as — mediaProvider would be
        // empty or 403 here. readOnly hides owner-only actions (Move,
        // Copy, Rename, Delete, Edit) that would otherwise try to
        // mutate media the guest has no rights over.
        if (m.type == MediaType.photo) {
          Navigator.of(context).pushNamed(
            AppRoutes.imageViewer,
            arguments: ImageViewerArgs(
              mediaIds: allMedia.map((x) => x.id).toList(),
              initialIndex: allMedia.indexOf(m),
              showWatermark: showWatermark,
              allowDownload: allowDownload,
              shareLinkId: widget.token,
              watermarkUrl: watermarkUrl,
              mediaItems: allMedia,
              readOnly: true,
            ),
          );
        } else {
          Navigator.of(context).pushNamed(
            AppRoutes.videoPlayer,
            arguments: VideoPlayerArgs(
              mediaId: m.id,
              mediaIds: allMedia.map((x) => x.id).toList(),
              initialIndex: allMedia.indexOf(m),
              showWatermark: showWatermark,
              allowDownload: allowDownload,
              shareLinkId: widget.token,
              watermarkUrl: watermarkUrl,
              mediaItems: allMedia,
              readOnly: true,
            ),
          );
        }
      },
      behavior: HitTestBehavior.opaque,
      onLongPress: () {
        if (!allowDownload) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Downloads are disabled for this gallery.')),
          );
          return;
        }
        _toggleSelection(m.id);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            imageWidget,
            if (m.type == MediaType.video)
              Positioned(
                bottom: 6,
                right: 6,
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            if (showWatermark && watermarkUrl != null && watermarkUrl.isNotEmpty)
              WatermarkOverlay(
                url: watermarkUrl,
                heightFraction: 0.16,
                minHeight: 12,
                maxHeight: 40,
              ),
            if (_selectedIds.contains(m.id))
              Positioned.fill(
                child: Container(
                  color: AppColors.primary.withValues(alpha: 0.3),
                  alignment: Alignment.topLeft,
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.check_circle_rounded,
                      color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
