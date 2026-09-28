import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/common/app_popup.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../widgets/inputs/cascading_location_picker.dart';
import '../../widgets/inputs/custom_text_field.dart';
import '../../core/theme/theme_context.dart';

/// Specializations a Studio can tag themselves with — shown as selectable
/// chips on step "Studio business details" (photographer role only).
const List<String> kStudioSpecializations = [
  'Wedding',
  'Portrait',
  'Event',
  'Product'
];

/// Final onboarding step: profile photo placeholder + personal details.
/// No image picker package is wired up (no backend / no API per the
/// brief) — tapping the avatar shows a dummy "coming soon" snackbar.
///
/// When [role] is [UserRole.photographer] this also collects Studio
/// business details (Studio Name + Specialization) — mirrors the same
/// `widget.role` branching pattern used on `register_screen.dart` step 3,
/// so Studio accounts finish onboarding with the info clients search on.
/// Saving advances into the Camera / Photo Library / Push Notification
/// permission prompts, not straight to Home / Admin Home.
///
/// Every field is prefilled from [authProvider]'s current [AppUser] on
/// load — if that user data isn't in memory yet (e.g. app was just
/// restarted), a fresh `GET /auth/me` is forced via `refreshMe()` first,
/// which is what was missing before and caused this screen to always
/// show blank/stale fields regardless of what was already saved.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  final UserRole? role;
  const CompleteProfileScreen({super.key, this.role});

  @override
  ConsumerState<CompleteProfileScreen> createState() =>
      _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  String? _country;
  String? _state;
  String? _city;
  final _addressController = TextEditingController();
  final _bioController = TextEditingController();

  // Studio-only fields (photographer role)
  final _studioNameController = TextEditingController();
  final Set<String> _specializations = {};

  bool _isSaving = false;

  bool get _isPhotographer => widget.role == UserRole.photographer;

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
  }

  /// Reads the current user from [authProvider]; if it's missing/stale
  /// (nothing loaded yet, or a previous fetch failed), forces a fresh
  /// `GET /auth/me` via `refreshMe()` before prefilling. This is the
  /// piece that was missing before, causing this screen to always show
  /// blank fields no matter what had actually been saved server-side.
  Future<void> _loadCurrentUser() async {
    var user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      try {
        await ref.read(authProvider.notifier).refreshMe();
      } on ApiException {
        // Leave fields blank — the user can still fill them in and Save.
      }
      user = ref.read(authProvider).valueOrNull;
    }
    if (!mounted || user == null) return;

    setState(() {
      _nameController.text = user!.fullName;
      _country = user.country;
      _state = user.state;
      _city = user.city;
      _addressController.text = user.address ?? '';
      _bioController.text = user.bio ?? '';
      if (_isPhotographer) {
        _studioNameController.text = user.studioName ?? '';
        _specializations
          ..clear()
          ..addAll(user.specializations ?? const []);
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isPhotographer && _specializations.isEmpty) {
      AppToast.show(context, 'Select at least one specialization',
          isError: true);
      return;
    }
    setState(() => _isSaving = true);

    try {
      await ref.read(authProvider.notifier).completeProfile(
            fullName: _nameController.text.trim(),
            country: _country,
            state: _state,
            city: _city,
            address: _addressController.text.trim().isEmpty
                ? null
                : _addressController.text.trim(),
            bio: _bioController.text.trim().isEmpty
                ? null
                : _bioController.text.trim(),
            studioName:
                _isPhotographer ? _studioNameController.text.trim() : null,
            specializations: _isPhotographer ? _specializations.toList() : null,
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      await AppPopup.show(context,
          title: 'Something Went Wrong', message: e.message, isError: true);
      return;
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    Navigator.of(context).pushReplacementNamed(AppRoutes.cameraPermission,
        arguments: widget.role);
  }

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _addressController,
      _bioController,
      _studioNameController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
          title: _isPhotographer ? 'Studio Details' : 'Complete Profile'),
      body: ScreenBackdrop(
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Stack(
                          children: [
                            Container(
                              width: 104,
                              height: 104,
                              decoration: BoxDecoration(
                                gradient: AppColors.heroGradient,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                      color: AppColors.primary
                                          .withValues(alpha: 0.3),
                                      blurRadius: 30,
                                      offset: const Offset(0, 12)),
                                ],
                              ),
                              child: Icon(
                                _isPhotographer
                                    ? Icons.storefront_rounded
                                    : Icons.person_rounded,
                                color: Colors.white,
                                size: 48,
                              ),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: InkWell(
                                onTap: () => AppToast.show(
                                    context, 'Photo upload — coming soon'),
                                borderRadius: BorderRadius.circular(100),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: context.borderColor),
                                    boxShadow: [
                                      BoxShadow(
                                          color: AppColors.primary
                                              .withValues(alpha: 0.2),
                                          blurRadius: 10)
                                    ],
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded,
                                      size: 16, color: AppColors.primary),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      CustomTextField(
                        label: 'Name',
                        icon: Icons.person_outline_rounded,
                        controller: _nameController,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Name is required'
                            : null,
                      ),
                      if (_isPhotographer) ...[
                        const SizedBox(height: AppSpacing.md),
                        CustomTextField(
                          label: 'Studio Name',
                          icon: Icons.storefront_rounded,
                          controller: _studioNameController,
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Studio name is required'
                              : null,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      CascadingLocationPicker(
                        initialCountry: _country,
                        initialState: _state,
                        initialCity: _city,
                        onChanged: (country, state, city) {
                          setState(() {
                            _country = country;
                            _state = state;
                            _city = city;
                          });
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      CustomTextField(
                          label: 'Address',
                          icon: Icons.home_outlined,
                          controller: _addressController,
                          maxLines: 2),
                      if (_isPhotographer) ...[
                        const SizedBox(height: AppSpacing.lg),
                        Text('Specialization',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontSize: 15)),
                        const SizedBox(height: 6),
                        Text(
                          'Select what this studio shoots — helps clients discover you.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: kStudioSpecializations.map((spec) {
                            final selected = _specializations.contains(spec);
                            return FilterChip(
                              label: Text(spec),
                              selected: selected,
                              onSelected: (v) => setState(() {
                                v
                                    ? _specializations.add(spec)
                                    : _specializations.remove(spec);
                              }),
                              showCheckmark: false,
                              labelStyle: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: selected ? Colors.white : context.textPrimary,
                              ),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.7),
                              selectedColor: AppColors.primary,
                              side: BorderSide(
                                  color: selected
                                      ? AppColors.primary
                                      : context.borderColor),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.pill)),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 4),
                            );
                          }).toList(),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      CustomTextField(
                          label: 'Bio',
                          icon: Icons.edit_note_rounded,
                          controller: _bioController,
                          maxLines: 3),
                      const SizedBox(height: AppSpacing.xl),
                      GradientButton(
                          label: 'Save',
                          isLoading: _isSaving,
                          onPressed: _save),
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
}
