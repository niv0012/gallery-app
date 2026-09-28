import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/buttons/gradient_button.dart';
import '../../widgets/cards/role_card.dart';
import '../../widgets/common/auth_container.dart';
import '../../widgets/common/logo_widget.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// The most important screen per the brief: two large, glass, gradient-
/// bordered role cards with a selection animation, followed by a Continue
/// button that carries the chosen [UserRole] into the Login screen.
class RoleSelectionScreen extends StatefulWidget {
  final bool selectOnly;
  const RoleSelectionScreen({super.key, this.selectOnly = false});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  UserRole? _selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Shrinks the body when the keyboard appears — combined with
      // SingleChildScrollView below this prevents the 3.9 px bottom overflow.
      resizeToAvoidBottomInset: true,
      body: ScreenBackdrop(
        child: SafeArea(
          child: AuthContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Center(child: LogoWidget(size: 56)),
                const SizedBox(height: AppSpacing.lg),
                Text('Choose Your Role',
                    style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 6),
                Text(
                  'Tell us how you\'ll use PicGallery so we can tailor your experience.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.textMuted),
                ),
                const SizedBox(height: AppSpacing.xl),
                RoleCard(
                  icon: Icons.photo_camera_rounded,
                  title: 'Photographer',
                  features: const [
                    'Manage studio',
                    'Upload albums',
                    'Client management'
                  ],
                  selected: _selected == UserRole.photographer,
                  onTap: () =>
                      setState(() => _selected = UserRole.photographer),
                ),
                const SizedBox(height: AppSpacing.md),
                RoleCard(
                  icon: Icons.photo_library_rounded,
                  title: 'Client',
                  features: const [
                    'View galleries',
                    'Download memories',
                    'Favorites'
                  ],
                  selected: _selected == UserRole.client,
                  onTap: () => setState(() => _selected = UserRole.client),
                ),
                const SizedBox(height: 48), // Spacing before continue button
                GradientButton(
                  label: 'Continue',
                  icon: Icons.arrow_forward_rounded,
                  onPressed: _selected == null
                      ? null
                      : () {
                          // TEMP DEBUG — remove once the client/studio
                          // role mismatch is confirmed fixed.
                          debugPrint(
                              '[ROLE_DEBUG] RoleSelection Continue tapped, _selected=$_selected');
                          if (widget.selectOnly) {
                            Navigator.of(context).pop(_selected);
                          } else {
                            Navigator.of(context).pushNamed(AppRoutes.login,
                                arguments: _selected);
                          }
                        },
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
