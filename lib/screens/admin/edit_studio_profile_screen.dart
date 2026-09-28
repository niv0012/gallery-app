import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../models/settings_model.dart';
import '../../models/studio_model.dart';
import '../../providers/auth_providers.dart';
import '../../providers/settings_provider.dart';
import '../../providers/studio_provider.dart';
import '../../providers/user_providers.dart';
import '../../services/media_picker_service.dart' show MediaContentType;
import '../../services/studio_logo_actions.dart';
import '../../services/studio_media_upload_service.dart'
    show StudioPortfolioImage;
import '../../widgets/cards/glass_card.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/common/snackbar_helper.dart';
import '../../widgets/inputs/cascading_location_picker.dart';

class EditStudioProfileScreen extends ConsumerStatefulWidget {
  final SettingsModel settings;

  const EditStudioProfileScreen({super.key, required this.settings});

  @override
  ConsumerState<EditStudioProfileScreen> createState() =>
      _EditStudioProfileScreenState();
}

class _EditStudioProfileScreenState
    extends ConsumerState<EditStudioProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _studioNameController;
  late final TextEditingController _photoNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _websiteController;
  late final TextEditingController _aboutController;
  late final TextEditingController _studioAddressController;
  late final TextEditingController _instagramController;
  late final TextEditingController _facebookController;
  late final TextEditingController _youtubeController;
  late final TextEditingController _pinterestController;

  String? _logoPath;
  String? _coverPath;
  List<String> _selectedCategories = [];
  bool _isSaving = false;

  // Country/State/City — real backend User columns (same ones the
  // client-facing Location section on shared/edit_profile_screen.dart
  // writes to), only ever set once at registration until now. Studios
  // never route through that shared screen, so this was the only place
  // in the app a studio could actually reach to edit them.
  String? _country;
  String? _state;
  String? _city;

  // Task 8 — logo/cover uploads go straight to the backend as soon as
  // they're picked (unlike the other fields on this screen, which only
  // save on the big "Save Changes" button), so these track per-thumbnail
  // spinner state independently of `_isSaving`.
  bool _isUploadingLogo = false;
  bool _isUploadingCover = false;

  // Showcase Portfolio grid.
  List<StudioPortfolioImage> _portfolioImages = [];
  bool _isLoadingPortfolio = false;
  bool _isAddingPortfolioImage = false;
  final Set<String> _deletingPortfolioIds = {};

  final List<String> _availableSpecializations = [
    'Wedding',
    'Portrait',
    'Fashion',
    'Editorial',
    'Event',
    'Landscape',
    'Family'
  ];

  void _syncBrandingFromSource() {
    final authUser = ref.read(authProvider).valueOrNull;
    final studioNotifier = ref.read(studioProvider.notifier);
    final studio = studioNotifier.studios.cast<StudioModel?>().firstWhere(
          (s) => s?.id == widget.settings.studioId,
          orElse: () => studioNotifier.studios.cast<StudioModel?>().firstWhere(
                (s) => s?.email == widget.settings.email,
                orElse: () => null,
              ),
        );

    final String? nextLogo;
    if (authUser != null) {
      // The signed-in user's avatar is the source of truth; an empty value
      // means "no logo" and must not fall back to stale cached copies.
      final avatar = authUser.avatarUrl;
      nextLogo = (avatar != null && avatar.isNotEmpty) ? avatar : null;
    } else {
      nextLogo = studio?.logoUrl ?? _logoPath;
    }
    final nextCover = authUser?.coverImageUrl ?? studio?.coverUrl ?? _coverPath;

    if (_logoPath != nextLogo || _coverPath != nextCover) {
      setState(() {
        _logoPath = nextLogo;
        _coverPath = nextCover;
      });
    }
  }

  @override
  void initState() {
    super.initState();

    // Identity fields (Studio Name / Photographer Name / Email) come from
    // the authenticated backend User row, not the local Hive-cached
    // SettingsModel — that cache is what was causing every account to show
    // the same hardcoded placeholder. Prefer whatever's already loaded in
    // authProvider; if nothing's cached yet (e.g. straight after a cold
    // app restart before the profile tab has been visited), fall back to
    // the settings snapshot for the very first frame and kick off a fresh
    // GET /auth/me to replace it.
    final cachedUser = ref.read(authProvider).valueOrNull;
    final currentSettings = ref.read(settingsProvider);
    _studioNameController = TextEditingController(
      text: cachedUser?.studioName ?? currentSettings.studioName,
    );
    _photoNameController = TextEditingController(
      text: cachedUser?.fullName ?? currentSettings.photographerName,
    );
    _emailController = TextEditingController(
      text: cachedUser?.email ?? currentSettings.email,
    );
    // Studio's own street address — a real backend User column
    // (`studio_address`), only ever set once at registration until now;
    // wired up here the same way Studio Name/Photographer Name are.
    _studioAddressController = TextEditingController(
      text: cachedUser?.studioAddress ?? '',
    );
    _country = cachedUser?.country;
    _state = cachedUser?.state;
    _city = cachedUser?.city;
    if (cachedUser == null) {
      _loadCurrentUser();
    }

    _loadPortfolio();

    // Look up existing StudioModel if present
    final studioNotifier = ref.read(studioProvider.notifier);
    final studio = studioNotifier.studios.cast<StudioModel?>().firstWhere(
          (s) => s?.id == widget.settings.studioId,
          orElse: () => studioNotifier.studios.cast<StudioModel?>().firstWhere(
                (s) => s?.email == widget.settings.email,
                orElse: () => null,
              ),
        );

    if (studio != null) {
      _aboutController = TextEditingController(text: studio.about);
    } else {
      _aboutController = TextEditingController();
    }

    _syncBrandingFromSource();

    // Seed website from the backend-synced cachedUser field first, then
    // fall back to the local settings cache so the value still shows if
    // the auth cache has not refreshed yet.
    _websiteController = TextEditingController(
        text: cachedUser?.website ?? currentSettings.website);
    _instagramController =
        TextEditingController(text: cachedUser?.instagramUrl);
    _facebookController = TextEditingController(text: cachedUser?.facebookUrl);
    _youtubeController = TextEditingController(text: cachedUser?.youtubeUrl);
    _pinterestController =
        TextEditingController(text: cachedUser?.pinterestUrl);

    // Seed specializations from the backend-synced cachedUser field, not from
    // the local-only studio.categories cache (which never gets updated when
    // the user saves changes). This is the same source-of-truth that the Save
    // button writes to and that's used everywhere else on screen.
    _selectedCategories = cachedUser?.specializations ?? [];
  }

  /// Forces a `GET /auth/me` when [initState] found nothing cached in
  /// [authProvider] yet, then re-seeds the identity controllers from the
  /// result. Errors are swallowed here (same as `EditProfileScreen`'s
  /// `_loadCurrentUser`) — the fields just keep showing the settings-cache
  /// fallback they were seeded with, rather than blocking the screen.
  Future<void> _loadCurrentUser() async {
    try {
      await ref.read(authProvider.notifier).refreshMe();
    } on ApiException {
      return;
    }
    if (!mounted) return;
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) return;
    setState(() {
      _studioNameController.text =
          user.studioName ?? _studioNameController.text;
      _photoNameController.text = user.fullName;
      _emailController.text = user.email;
      _studioAddressController.text =
          user.studioAddress ?? _studioAddressController.text;
      _websiteController.text =
          user.website ?? ref.read(settingsProvider).website;
      _instagramController.text =
          user.instagramUrl ?? _instagramController.text;
      _facebookController.text = user.facebookUrl ?? _facebookController.text;
      _youtubeController.text = user.youtubeUrl ?? _youtubeController.text;
      _pinterestController.text =
          user.pinterestUrl ?? _pinterestController.text;
      _country = user.country ?? _country;
      _state = user.state ?? _state;
      _city = user.city ?? _city;
    });
  }

  @override
  void dispose() {
    _studioNameController.dispose();
    _photoNameController.dispose();
    _emailController.dispose();
    _websiteController.dispose();
    _aboutController.dispose();
    _studioAddressController.dispose();
    _instagramController.dispose();
    _facebookController.dispose();
    _youtubeController.dispose();
    _pinterestController.dispose();
    super.dispose();
  }

  /// Tap on the logo camera badge: straight to the picker when there is no
  /// logo yet, otherwise a Change / Remove sheet.
  Future<void> _onLogoBadgeTap() async {
    if (_isUploadingLogo) return;
    final hasLogo = _logoPath != null && _logoPath!.isNotEmpty;
    if (!hasLogo) {
      await _pickImage(true);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Change logo'),
              onTap: () => Navigator.of(ctx).pop('change'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.error),
              title: const Text('Remove logo',
                  style: TextStyle(color: AppColors.error)),
              onTap: () => Navigator.of(ctx).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'change') await _pickImage(true);
    if (action == 'remove') await _removeLogo();
  }

  /// Removes the studio logo (`DELETE /studios/me/avatar`) after a
  /// confirmation. Like uploads, it applies immediately — no need to press
  /// "Save Changes".
  Future<void> _removeLogo() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove logo?'),
        content:
            const Text('Your studio will go back to the default camera icon.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _isUploadingLogo = true);
    try {
      await StudioLogoActions.remove(container);
      if (!mounted) return;
      setState(() => _logoPath = null);
      SnackBarHelper.showSuccess(context, 'Studio logo removed.');
    } catch (_) {
      if (mounted) {
        SnackBarHelper.showError(
            context, "Couldn't remove the logo. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _isUploadingLogo = false);
    }
  }

  /// Picks a logo ([isLogo] true) or cover ([isLogo] false) image and
  /// uploads it immediately via `studioProfileRepositoryProvider` —
  /// unlike every other field on this screen, branding assets don't wait
  /// for "Save Changes" since the backend endpoints
  /// (`POST /studios/me/avatar` / `/cover`) are single-purpose uploads,
  /// not part of the profile PATCH body. Shows a spinner overlay on the
  /// thumbnail while in flight, reverts to the previous image on
  /// failure, and swaps in the server URL on success.
  Future<void> _pickImage(bool isLogo) async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
      return;
    }
    if (picked == null) return;

    final previousPath = isLogo ? _logoPath : _coverPath;
    setState(() {
      if (isLogo) {
        _isUploadingLogo = true;
      } else {
        _isUploadingCover = true;
      }
    });

    try {
      final bytes = await picked.readAsBytes();
      final contentType =
          picked.mimeType ?? MediaContentType.forFileName(picked.name);
      final repo = ref.read(studioProfileRepositoryProvider);
      final url = isLogo
          ? await repo.uploadAvatar(
              bytes: bytes, fileName: picked.name, contentType: contentType)
          : await repo.uploadCover(
              bytes: bytes, fileName: picked.name, contentType: contentType);

      if (!mounted) return;

      final newPath = url ?? previousPath;
      setState(() {
        if (isLogo) {
          _logoPath = newPath;
        } else {
          _coverPath = newPath;
        }
      });

      ref.read(studioProvider.notifier).updateCachedBranding(
            logoUrl: isLogo ? newPath : null,
            coverUrl: !isLogo ? newPath : null,
          );

      await ref.read(authProvider.notifier).refreshMe();
      final refreshedUser = ref.read(authProvider).valueOrNull;
      if (refreshedUser != null && newPath != null && newPath.isNotEmpty) {
        if (isLogo) {
          ref
              .read(authProvider.notifier)
              .setUser(refreshedUser.copyWith(avatarUrl: newPath));
        } else {
          ref
              .read(authProvider.notifier)
              .setUser(refreshedUser.copyWith(coverImageUrl: newPath));
        }
      }

      try {
        await ref.read(studioProvider.notifier).loadDirectory();
      } catch (_) {
        // Best-effort refresh — the backend upload already persisted the
        // brand asset; if directory loading fails, the user still sees the
        // updated image on their own account, and the next successful load
        // will populate it everywhere else.
      }

      if (mounted) {
        _syncBrandingFromSource();
      }

      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          isLogo
              ? 'Studio logo updated successfully.'
              : 'Cover photo updated successfully.',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading image: $e'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      // Revert — the thumbnail should never look like the upload
      // succeeded when it didn't.
      if (isLogo) {
        _logoPath = previousPath;
      } else {
        _coverPath = previousPath;
      }
    } finally {
      if (mounted) {
        setState(() {
          if (isLogo) {
            _isUploadingLogo = false;
          } else {
            _isUploadingCover = false;
          }
        });
      }
    }
  }

  /// Loads the current studio's Showcase Portfolio grid
  /// (`GET /studios/me/portfolio`). Failure is silent — the grid just
  /// stays empty rather than blocking this already-busy screen with
  /// another error banner.
  Future<void> _loadPortfolio() async {
    setState(() => _isLoadingPortfolio = true);
    try {
      final images =
          await ref.read(studioProfileRepositoryProvider).fetchPortfolio();
      if (!mounted) return;
      setState(() => _portfolioImages = images);
    } catch (_) {
      // Silent — see doc comment above.
    } finally {
      if (mounted) setState(() => _isLoadingPortfolio = false);
    }
  }

  /// Picks and uploads one image into the Showcase Portfolio grid
  /// (`POST /studios/me/portfolio`). New image is prepended so it shows
  /// up first, matching the backend's newest-first ordering.
  Future<void> _pickPortfolioImage() async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
      return;
    }
    if (picked == null) return;

    setState(() => _isAddingPortfolioImage = true);
    try {
      final bytes = await picked.readAsBytes();
      final contentType =
          picked.mimeType ?? MediaContentType.forFileName(picked.name);
      final image =
          await ref.read(studioProfileRepositoryProvider).addPortfolioImage(
                bytes: bytes,
                fileName: picked.name,
                contentType: contentType,
              );
      if (!mounted) return;
      setState(() => _portfolioImages = [image, ..._portfolioImages]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading image: $e'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isAddingPortfolioImage = false);
    }
  }

  /// Removes one image from the Showcase Portfolio grid
  /// (`DELETE /studios/me/portfolio/{id}`), optimistically, reverting
  /// the grid back on failure.
  Future<void> _deletePortfolioImage(String imageId) async {
    final previousImages = List<StudioPortfolioImage>.from(_portfolioImages);
    setState(() {
      _deletingPortfolioIds.add(imageId);
      _portfolioImages =
          _portfolioImages.where((img) => img.id != imageId).toList();
    });

    try {
      await ref
          .read(studioProfileRepositoryProvider)
          .deletePortfolioImage(imageId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _portfolioImages = previousImages);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error removing image: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingPortfolioIds.remove(imageId));
      }
    }
  }

  Widget _buildImageWidget(
    String? path,
    IconData placeholderIcon,
    double height,
    double width, {
    bool isCircle = false,
    bool isUploading = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitleColor =
        isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    final placeholderBg = isDark
        ? AppColors.darkSurfaceRaised
        : AppColors.background.withValues(alpha: 0.8);
    final placeholderBorder = isDark ? AppColors.darkBorder : AppColors.border;

    final hasImage = path != null && path.isNotEmpty;

    Widget imageChild;
    if (hasImage) {
      if (path.startsWith('http')) {
        imageChild = Image.network(
          path,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              Icon(placeholderIcon, size: 28, color: subtitleColor),
        );
      } else {
        imageChild = Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              Icon(placeholderIcon, size: 28, color: subtitleColor),
        );
      }
    } else {
      imageChild = Icon(placeholderIcon, size: 28, color: subtitleColor);
    }

    Widget clip(Widget child) => isCircle
        ? ClipOval(child: child)
        : ClipRRect(borderRadius: BorderRadius.circular(10), child: child);

    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: placeholderBg,
        borderRadius: isCircle ? null : BorderRadius.circular(12),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        border: Border.all(color: placeholderBorder, width: 1.5),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          clip(imageChild),
          if (isUploading)
            clip(
              Container(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final settingsNotifier = ref.read(settingsProvider.notifier);
      final studioNotifier = ref.read(studioProvider.notifier);

      // Studio Name / Photographer Name are real backend User columns
      // (studio_name / full_name) — save them via PATCH /users/me instead
      // of only the local Hive cache, and push the canonical response back
      // into authProvider so every other screen watching the current user
      // (profile tab greeting, etc.) reflects the change immediately.
      final updatedUser = await ref.read(userRepositoryProvider).updateProfile(
            fullName: _photoNameController.text.trim(),
            studioName: _studioNameController.text.trim(),
            studioAddress: _studioAddressController.text.trim(),
            country: _country,
            state: _state,
            city: _city,
            // Bio maps to the "About / Business Description" textarea.
            bio: _aboutController.text.trim(),
            // Website URL
            website: _websiteController.text.trim(),
            instagramUrl: _instagramController.text.trim(),
            facebookUrl: _facebookController.text.trim(),
            youtubeUrl: _youtubeController.text.trim(),
            pinterestUrl: _pinterestController.text.trim(),
            // Categories/Specializations map to the specializations column.
            specializations:
                _selectedCategories.isNotEmpty ? _selectedCategories : null,
          );
      ref.read(authProvider.notifier).setUser(updatedUser);

      // Mirror the saved values into the local settings cache too — other
      // parts of the app (e.g. widgets still reading settingsProvider
      // directly rather than authProvider) stay in sync until they're
      // migrated over to the backend-backed value as well. Email isn't
      // editable via the backend (or this screen — the field is disabled),
      // so it's mirrored straight from the canonical backend value instead
      // of the controller, which never changes anyway.
      final updatedSettings = widget.settings.copyWith(
        studioName: updatedUser.studioName,
        photographerName: updatedUser.fullName,
        email: updatedUser.email,
        website: _websiteController.text.trim(),
      );
      await settingsNotifier.updateSettings(updatedSettings);

      // Find original StudioModel
      var studio = studioNotifier.studios.cast<StudioModel?>().firstWhere(
            (s) => s?.id == widget.settings.studioId,
            orElse: () =>
                studioNotifier.studios.cast<StudioModel?>().firstWhere(
                      (s) => s?.email == widget.settings.email,
                      orElse: () => null,
                    ),
          );

      final studioIdToUse = studio?.id ?? widget.settings.studioId;

      // NOTE: Logo/Cover/About/Categories/Website are still
      // local-only (StudioNotifier's `_studios` list is now the real
      // client-facing `GET /studios` directory, which this admin screen
      // has no update method for and — being client-only on the backend
      // — a photographer account can't even call). Same scope note as
      // Studio Name/Photographer Name/Email had before those were wired
      // to the backend above: flag if/when these fields should get real
      // backend columns and an admin-facing update endpoint.

      // Verify and sync studioId
      if (widget.settings.studioId != studioIdToUse) {
        await settingsNotifier.updateSettings(
          updatedSettings.copyWith(studioId: studioIdToUse),
        );
      }

      if (mounted) {
        SnackBarHelper.showSuccess(
            context, 'Studio profile updated successfully.');
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: (Theme.of(context).brightness == Brightness.dark
                ? AppColors.darkSurface
                : AppColors.surface),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            title: Row(
              children: [
                Icon(Icons.check_circle_rounded,
                    color: AppColors.success, size: 24),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Profile saved',
                    style: TextStyle(
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textOnDark
                          : AppColors.text),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              'Your studio branding and profile details have been updated and are now visible.',
              style: TextStyle(
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.subtitleOnDark
                      : AppColors.subtitle)),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pop();
                },
                child: Text(
                  'Done',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: ${e.message}'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: $e'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppColors.textOnDark : AppColors.text;
    final subtitleColor =
        isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    final placeholderBg = isDark
        ? AppColors.darkSurfaceRaised
        : AppColors.background.withValues(alpha: 0.8);
    final placeholderBorder = isDark ? AppColors.darkBorder : AppColors.border;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const CustomAppBar(title: 'Edit Studio Profile', showBack: true),
      body: ScreenBackdrop(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(top: kToolbarHeight),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.all(AppSpacing.md),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Cover & Logo Photo Selectors
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Branding Assets',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          // Cover banner selector
                          Stack(
                            children: [
                              _buildImageWidget(_coverPath,
                                  Icons.landscape_rounded, 130, double.infinity,
                                  isUploading: _isUploadingCover),
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    shape: BoxShape.circle,
                                  ),
                                  child: IconButton(
                                    icon: Icon(Icons.camera_alt_rounded,
                                        color: Colors.white, size: 18),
                                    onPressed: () => _pickImage(false),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          // Logo avatar selector
                          Row(
                            children: [
                              Stack(
                                children: [
                                  _buildImageWidget(
                                      _logoPath, Icons.business_rounded, 80, 80,
                                      isCircle: true,
                                      isUploading: _isUploadingLogo),
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      height: 32,
                                      width: 32,
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: Colors.white, width: 2),
                                      ),
                                      child: IconButton(
                                        icon: Icon(Icons.camera_alt_rounded,
                                            color: Colors.white, size: 14),
                                        onPressed: _onLogoBadgeTap,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Studio Logo & Cover Photo',
                                      style: TextStyle(
                                        color: textColor,
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Upload JPG/PNG assets. These will be shown on your client facing portal.',
                                      style: TextStyle(
                                        color: subtitleColor,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    if (_logoPath != null &&
                                        _logoPath!.isNotEmpty) ...[
                                      SizedBox(height: 6),
                                      TextButton.icon(
                                        onPressed: _isUploadingLogo
                                            ? null
                                            : _removeLogo,
                                        icon: Icon(
                                            Icons.delete_outline_rounded,
                                            size: 16),
                                        label: Text('Remove logo'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: AppColors.error,
                                          padding: EdgeInsets.zero,
                                          minimumSize: Size(0, 32),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          alignment: Alignment.centerLeft,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),

                    // 1b. Showcase Portfolio grid
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Showcase Portfolio',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Add a few of your best shots to show clients on your public profile.',
                            style:
                                TextStyle(color: subtitleColor, fontSize: 11.5),
                          ),
                          SizedBox(height: 12),
                          if (_isLoadingPortfolio)
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          else
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _portfolioImages.length + 1,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                              itemBuilder: (context, index) {
                                if (index == _portfolioImages.length) {
                                  return GestureDetector(
                                    onTap: _isAddingPortfolioImage
                                        ? null
                                        : _pickPortfolioImage,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: placeholderBg,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                            color: placeholderBorder,
                                            width: 1.5),
                                      ),
                                      child: Center(
                                        child: _isAddingPortfolioImage
                                            ? SizedBox(
                                                height: 20,
                                                width: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2),
                                              )
                                            : Icon(Icons.add_rounded,
                                                color: subtitleColor, size: 28),
                                      ),
                                    ),
                                  );
                                }

                                final image = _portfolioImages[index];
                                final isDeleting =
                                    _deletingPortfolioIds.contains(image.id);
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.network(
                                        image.url,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                Container(
                                          color: placeholderBg,
                                          child: Icon(
                                              Icons.broken_image_rounded,
                                              color: subtitleColor),
                                        ),
                                      ),
                                    ),
                                    if (isDeleting)
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Container(
                                          color: Colors.black
                                              .withValues(alpha: 0.45),
                                          child: Center(
                                            child: SizedBox(
                                              height: 18,
                                              width: 18,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      )
                                    else
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: GestureDetector(
                                          onTap: () =>
                                              _deletePortfolioImage(image.id),
                                          child: Container(
                                            padding: EdgeInsets.all(2),
                                            decoration: BoxDecoration(
                                                color: Colors.black54,
                                                shape: BoxShape.circle),
                                            child: Icon(Icons.close_rounded,
                                                color: Colors.white, size: 14),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),

                    // 2. Identity info fields card
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Identity & Contact Info',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          TextFormField(
                            controller: _studioNameController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration:
                                const InputDecoration(labelText: 'Studio Name'),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Enter studio name'
                                : null,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _photoNameController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                                labelText: 'Photographer Name'),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Enter photographer name'
                                : null,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _studioAddressController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                                labelText: 'Studio Address'),
                            maxLines: 2,
                          ),
                          SizedBox(height: AppSpacing.md),
                          CascadingLocationPicker(
                            initialCountry: _country,
                            initialState: _state,
                            initialCity: _city,
                            onChanged: (country, state, city) {
                              _country = country;
                              _state = state;
                              _city = city;
                            },
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _emailController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            enabled: false,
                            decoration: const InputDecoration(
                              labelText: 'Email Address',
                              helperText:
                                  'Email can\'t be changed here. Contact support to update it.',
                              helperMaxLines: 2,
                            ),
                            keyboardType: TextInputType.emailAddress,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _websiteController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration:
                                const InputDecoration(labelText: 'Website URL'),
                            keyboardType: TextInputType.url,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),

                    // 3. Social Media Links
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Social Media Links',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          TextFormField(
                            controller: _instagramController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                                labelText: 'Instagram URL'),
                            keyboardType: TextInputType.url,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _facebookController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                                labelText: 'Facebook URL'),
                            keyboardType: TextInputType.url,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _youtubeController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration:
                                const InputDecoration(labelText: 'YouTube URL'),
                            keyboardType: TextInputType.url,
                          ),
                          SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _pinterestController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                                labelText: 'Pinterest URL'),
                            keyboardType: TextInputType.url,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),

                    // 4. Specialization Choice Chips
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Specializations / Categories',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _availableSpecializations.map((cat) {
                              final isSelected =
                                  _selectedCategories.contains(cat);
                              return FilterChip(
                                selected: isSelected,
                                label: Text(cat),
                                labelStyle: TextStyle(
                                  color: isSelected ? Colors.white : textColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                selectedColor: AppColors.primary,
                                checkmarkColor: Colors.white,
                                backgroundColor: isDark
                                    ? AppColors.darkSurfaceRaised
                                    : Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: BorderSide(
                                    color: isSelected
                                        ? AppColors.primary
                                        : (isDark
                                            ? AppColors.darkBorder
                                            : AppColors.border),
                                  ),
                                ),
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedCategories.add(cat);
                                    } else {
                                      _selectedCategories.remove(cat);
                                    }
                                  });
                                },
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),

                    // 5. Business description multiline card
                    GlassCard(
                      borderRadius: 16,
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Business Description',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 12),
                          TextFormField(
                            controller: _aboutController,
                            maxLines: 4,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: const InputDecoration(
                              hintText:
                                  'Tell clients about your studio philosophy, equipment, experience, and style...',
                              alignLabelWithHint: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.lg),

                    // 5. Save Button
                    Container(
                      width: double.infinity,
                      height: 52,
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.24),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _handleSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _isSaving
                            ? const CircularProgressIndicator(
                                color: Colors.white)
                            : Text(
                                'Save Changes',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                    SizedBox(height: AppSpacing.xl),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
