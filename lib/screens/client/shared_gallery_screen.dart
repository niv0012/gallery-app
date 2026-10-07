import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final Set<String> _favouriteIds = {};
  String? _guestEmail;


  Future<void> _loadGuestEmail() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _guestEmail = prefs.getString('guest_email');
    });
  }

  Future<void> _promptForEmailAndFavourite(String mediaId, PublicGalleryController controller) async {
    final emailCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Email'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Please provide your email to favourite photos.'),
              const SizedBox(height: 16),
              TextFormField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Email Address',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val != null && val.contains('@') ? null : 'Enter a valid email',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(emailCtrl.text.trim());
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (email != null && email.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('guest_email', email);
      setState(() {
        _guestEmail = email;
      });
      _toggleFavourite(mediaId, controller);
    }
  }

  Future<void> _toggleFavourite(String mediaId, PublicGalleryController controller) async {
    if (_guestEmail == null) {
      return _promptForEmailAndFavourite(mediaId, controller);
    }

    final isFav = _favouriteIds.contains(mediaId);
    setState(() {
      if (isFav) {
        _favouriteIds.remove(mediaId);
      } else {
        _favouriteIds.add(mediaId);
      }
    });

    try {
      await controller.toggleFavourite(mediaId, _guestEmail!);
    } catch (e) {
      // Revert on error
      if (mounted) {
        setState(() {
          if (isFav) {
            _favouriteIds.add(mediaId);
          } else {
            _favouriteIds.remove(mediaId);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update favourite')),
        );
      }
    }
  }

  bool get _isSelectionMode => _selectedIds.isNotEmpty;
  String _selectedFilterTab = 'All';

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
    _loadGuestEmail();
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
        final faceSearchState = ref.watch(faceSearchProvider);
        if (controller.data!.kind == 'face_search' && faceSearchState.searchResults.isEmpty) {
          return _buildFaceSearchGate(context, controller.data!, controller);
        }
        return _buildGallery(context, controller.data!, controller);
    }
  }

  Widget _buildFaceSearchGate(BuildContext context, PublicGalleryData data, PublicGalleryController controller) {
    return Scaffold(
      appBar: CustomAppBar(title: 'Find My Photos', showBack: true),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: GlassCard(
                padding: EdgeInsets.all(AppSpacing.xl),
                borderRadius: AppRadius.lg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.face_retouching_natural_rounded, color: AppColors.primary, size: 24),
                        SizedBox(width: 10),
                        Text(
                          'Selfie Search Required',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'The photographer requires you to upload a selfie to view your photos. Only photos containing your face will be shown.',
                      style: TextStyle(
                          fontSize: 13,
                          color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                          height: 1.4),
                    ),
                    SizedBox(height: AppSpacing.xl),
                    GradientButton(
                      label: 'Take or Upload Selfie',
                      icon: Icons.camera_alt_rounded,
                      onPressed: () {
                        ref.read(faceSearchProvider.notifier).useSharedGallery(
                          token: data.token,
                          password: controller.password,
                        );
                        Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

  Future<void> _downloadMediaIds(
      List<String> ids,
      PublicGalleryData data,
      List<MediaModel> albumMedia,
      BuildContext context,
      WidgetRef ref,
      dynamic gridFileCache,
      dynamic gridDownloadService) async {
    final apiClient = ref.read(apiClientProvider);
    for (final id in ids) {
      final m = albumMedia.firstWhere((x) => x.id == id, orElse: () => albumMedia.first);
      if (m.id != id) continue; // Not found

      if (kIsWeb) {
        final result = await gridFileCache.bytesFor(
          m,
          watermarkUrl: data.showWatermark ? data.studioLogoUrl : null,
        );
        if (result == null) continue;
        if (!context.mounted) continue;
        await gridDownloadService.downloadBytes(
          context: context,
          bytes: result.bytes,
          fileName: result.fileName,
          mediaId: m.id,
          apiClient: apiClient,
          isClientUser: true,
        );
      } else {
        final filePath = await gridFileCache.localPathFor(
          m,
          watermarkUrl: data.showWatermark ? data.studioLogoUrl : null,
        );
        if (filePath == null) continue;
        if (!context.mounted) continue;
        await gridDownloadService.downloadOriginal(
          context: context,
          filePath: filePath,
          mediaId: m.id,
          apiClient: apiClient,
          isClientUser: true,
        );
      }
    }
  }

  Widget _buildGallery(BuildContext context, PublicGalleryData data,
      PublicGalleryController controller) {
    final faceSearchState = ref.watch(faceSearchProvider);
    final rawMedia = data.kind == 'face_search' 
        ? faceSearchState.searchResults.map((r) => r.media).toList() 
        : (data.media ?? []);

    final albumMedia = List<MediaModel>.from(rawMedia)
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final hasCover = albumMedia.isNotEmpty;
    final coverMedia = hasCover ? albumMedia.first : null;

    final filteredMedia = albumMedia.where((m) {
      if (_selectedFilterTab == 'Photos') return m.type == MediaType.photo;
      if (_selectedFilterTab == 'Videos') return m.type == MediaType.video;
      if (_selectedFilterTab == 'Favourite') return _favouriteIds.contains(m.id);
      return true;
    }).toList();

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
              pinned: true,
              elevation: 0,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              leadingWidth: 200,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(100),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Text('P', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('PicGallery', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text)),
                  ],
                ),
              ),
              actions: [
                IconButton(
                  icon: Icon(_isSelectionMode ? Icons.deselect_rounded : Icons.check_circle_outline_rounded, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                  onPressed: () {
                    setState(() {
                      if (_selectedIds.length == filteredMedia.length && filteredMedia.isNotEmpty) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(filteredMedia.map((m) => m.id));
                      }
                    });
                  },
                ),
                IconButton(
                  icon: Icon(Icons.share_outlined, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                  onPressed: () async {
                      final url = 'https://picgallery.studio/share/${widget.token}';
                      // just copy to clipboard or do nothing for now
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.isPreview) ...[
                      _buildPreviewBanner(),
                      const SizedBox(height: 12),
                    ],
                    _buildHeaderCard(context, data, albumMedia, controller),
                    const SizedBox(height: 24),
                    if (data.albums == null || data.albums!.isEmpty)
                      _buildFilterTabs(context),
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
                  : filteredMedia.isEmpty
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
                                    final m = filteredMedia[i];
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                      child: SizedBox(
                                        height: _viewMode == _ClientGalleryViewMode.details ? 300 : 150,
                                        child: _buildGridItem(
                                            context, m, albumMedia, data.showWatermark, data.allowDownload, data.studioLogoUrl),
                                      ),
                                    );
                                  },
                                  childCount: filteredMedia.length,
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
                                    final m = filteredMedia[i];
                                    return _buildGridItem(context, m, filteredMedia,
                                        data.showWatermark, data.allowDownload, data.studioLogoUrl);
                                  },
                                  childCount: filteredMedia.length,
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
                      await _downloadMediaIds(ids, data, albumMedia, context, ref, _gridFileCache, _gridDownloadService);
                    },
                    icon: Icon(Icons.download_rounded),
                    label: Text('Download ${_selectedIds.length} items'),
                    backgroundColor: AppColors.primary,
                  ),
                ],
              ],
            )
          : (albumMedia.isNotEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (data.allowDownload && data.kind != 'face_search')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: FloatingActionButton.extended(
                          heroTag: 'download_all_fab',
                          onPressed: () async {
                            final apiClient = ref.read(apiClientProvider);
                            String url = '${apiClient.baseUrl}/public/share-links/${widget.token}/download-zip';
                            final pwd = controller.password;
                            if (pwd != null && pwd.isNotEmpty) {
                              url += '?password=${Uri.encodeComponent(pwd)}';
                            }
                            if (widget.albumId != null) {
                              url += (url.contains('?') ? '&' : '?') + 'album_id=${widget.albumId}';
                            }
                            
                            final uri = Uri.parse(url);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            } else {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Could not open download link')),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.folder_zip_rounded),
                          label: const Text('Download All'),
                          backgroundColor: AppColors.primary,
                        ),
                      ),
                    if (data.kind == 'face_search' && data.allowDownload)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: FloatingActionButton.extended(
                          heroTag: 'download_all_mine_fab',
                          onPressed: () async {
                            final ids = albumMedia.map((e) => e.id).toList();
                            await _downloadMediaIds(ids, data, albumMedia, context, ref, _gridFileCache, _gridDownloadService);
                          },
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Download All Mine'),
                          backgroundColor: AppColors.primary,
                        ),
                      ),
                    if (data.kind == 'face_search')
                      FloatingActionButton.extended(
                        heroTag: 'send_me_my_photos_fab',
                        onPressed: () async {
                           try {
                             final ids = albumMedia.map((e) => e.id).toList();
                             final newToken = await controller.requestPrivateLink(ids);
                             if (!context.mounted) return;
                             showDialog(
                               context: context,
                               barrierDismissible: false,
                               builder: (context) => AlertDialog(
                                 title: Text('Photos Ready!'),
                                 content: Text('A private link containing only your photos has been created.'),
                                 actions: [
                                   TextButton(
                                     onPressed: () => Navigator.pop(context),
                                     child: Text('Close'),
                                   ),
                                   FilledButton(
                                     onPressed: () {
                                       Navigator.pop(context);
                                       final uri = Uri.parse('picgallery://shared/$newToken');
                                       launchUrl(uri).catchError((_) => false);
                                     },
                                     child: Text('Open Link'),
                                   ),
                                 ]
                               )
                             );
                           } catch (e) {
                             if (!context.mounted) return;
                             ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to request link')));
                           }
                        },
                        icon: const Icon(Icons.send_rounded),
                        label: const Text('Send me my photos'),
                        backgroundColor: AppColors.primary,
                      ),
                    if (data.kind != 'face_search')
                      FloatingActionButton.extended(
                        heroTag: 'shared_gallery_face_search_fab',
                        onPressed: () {
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
                  ),
                ],
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
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.hardEdge,
                child: InkWell(
                  onTap: () {
                    final controller = ref.read(publicGalleryControllerProvider(
                        PublicGalleryTarget(token: widget.token, albumId: widget.albumId)));
                    _toggleFavourite(m.id, controller);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      _favouriteIds.contains(m.id)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _favouriteIds.contains(m.id)
                          ? AppColors.error
                          : Colors.white,
                      size: 20,
                      shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
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
  Widget _buildHeaderCard(BuildContext context, PublicGalleryData data, List<MediaModel> allMedia, PublicGalleryController controller) {
    final studioName = 'Lumen Studio';
    final studioInitials = studioName.isNotEmpty ? studioName[0].toUpperCase() : 'S';
    final title = data.album?.name ?? data.collection?.name ?? 'Shared Gallery';
    
    final photoCount = allMedia.where((m) => m.type == MediaType.photo).length;
    final videoCount = allMedia.where((m) => m.type == MediaType.video).length;
    String countText = '';
    if (photoCount > 0) countText += '$photoCount photos';
    if (videoCount > 0) {
      if (countText.isNotEmpty) countText += ', ';
      countText += '$videoCount videos';
    }
    if (countText.isEmpty) countText = '0 items';
    if (data.albums != null && data.albums!.isNotEmpty) {
        countText = '${data.albums!.length} albums';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF13131A),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: AppColors.primary,
                child: Text(
                  studioInitials,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                studioName,
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.collections_rounded, size: 12, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(countText, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              // if (false)
              //   Container(
              //     padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              //     decoration: BoxDecoration(
              //       color: Colors.white.withValues(alpha: 0.1),
              //       borderRadius: BorderRadius.circular(100),
              //     ),
              //     child: Row(
              //       mainAxisSize: MainAxisSize.min,
              //       children: [
              //         const Icon(Icons.schedule_rounded, size: 12, color: Colors.white),
              //         const SizedBox(width: 6),
              //         Text(
              //           // '${data.expiryDate!.difference(DateTime.now()).inDays} days left',
              //           'Expiring soon',
              //           style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              //         ),
              //       ],
              //     ),
              //   ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                     if (data.allowDownload) {
                        _downloadMediaIds(allMedia.map((e) => e.id).toList(), data, allMedia, context, ref, _gridFileCache, _gridDownloadService);
                     } else {
                         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Downloads are disabled for this gallery.')));
                     }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download all', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    ref.read(faceSearchProvider.notifier).useSharedGallery(
                      token: widget.token,
                      password: controller.password,
                    );
                    Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.face_retouching_natural_rounded, size: 18),
                  label: const Text('Find my photos', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTabs(BuildContext context) {
    final tabs = ['All', 'Photos', 'Videos', 'Favourite'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: tabs.map((t) {
          final isSelected = _selectedFilterTab == t;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () {
                setState(() {
                  _selectedFilterTab = t;
                });
              },
              borderRadius: BorderRadius.circular(100),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : Colors.transparent,
                  border: Border.all(color: isSelected ? AppColors.primary : context.borderColor),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t == 'Favourite') ...[
                        Icon(isSelected ? Icons.favorite_rounded : Icons.favorite_border_rounded, 
                            size: 14, 
                            color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text)),
                        const SizedBox(width: 6),
                    ],
                    Text(
                      t,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                      ),
                    ),
                    if (t == 'Favourite') ...[
                        const SizedBox(width: 6),
                        Text(
                          _favouriteIds.length.toString(),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}


