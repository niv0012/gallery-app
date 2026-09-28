import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

/// A single row in [StudioDrawer]'s menu list.
///
/// - Selected: purple→pink gradient background, rounded corners, white
///   icon + white text.
/// - Unselected: transparent background, grey icon, dark text — with a
///   subtle hover tint on desktop/web and Material ink-ripple everywhere.
///
/// Kept as its own file/widget (per the brief) so both the main menu list
/// and any future drawer sections can reuse it without duplicating the
/// selected/unselected styling logic.
class DrawerMenuItem extends StatefulWidget {
  const DrawerMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
    this.trailingText,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Unread-count badge (e.g. Notifications). 0 hides the badge.
  final int badgeCount;

  /// Optional small trailing label (e.g. "Soon" for not-yet-built screens).
  final String? trailingText;

  @override
  State<DrawerMenuItem> createState() => _DrawerMenuItemState();
}

class _DrawerMenuItemState extends State<DrawerMenuItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            hoverColor: AppColors.primary.withValues(alpha: 0.06),
            splashColor: AppColors.primary.withValues(alpha: 0.15),
            highlightColor: AppColors.primary.withValues(alpha: 0.08),
            child: AnimatedContainer(
              duration: AppDurations.fast,
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 12),
              decoration: BoxDecoration(
                gradient: selected ? AppColors.buttonGradient : null,
                color: selected
                    ? null
                    : (_hovering
                        ? AppColors.primary.withValues(alpha: 0.05)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.28),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  AnimatedScale(
                    duration: AppDurations.fast,
                    scale: selected ? 1.08 : 1.0,
                    child: Icon(
                      widget.icon,
                      size: 21,
                      color: selected
                          ? Colors.white
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                        color: selected ? Colors.white : colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (widget.badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: selected ? context.surfaceColor : AppColors.accent,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        widget.badgeCount > 99 ? '99+' : '${widget.badgeCount}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: selected ? AppColors.primary : Colors.white,
                        ),
                      ),
                    )
                  else if (widget.trailingText != null)
                    Text(
                      widget.trailingText!,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? Colors.white70
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
