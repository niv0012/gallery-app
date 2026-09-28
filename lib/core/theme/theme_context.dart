import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Brightness-aware colour tokens so screens never hardcode a light-only
/// (or dark-only) colour for text, borders or surfaces.
///
/// Usage: `Text('Hi', style: TextStyle(color: context.textPrimary))`.
///
/// Keep `Colors.white` for content that sits on top of a photo, video,
/// gradient or a primary-coloured button — those are theme independent.
extension ThemeColors on BuildContext {
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  /// Main body text / icons on a surface.
  Color get textPrimary =>
      isDarkMode ? AppColors.textOnDark : AppColors.text;

  /// Secondary / muted text and icons.
  Color get textMuted =>
      isDarkMode ? AppColors.subtitleOnDark : AppColors.subtitle;

  /// Hairline borders and dividers.
  Color get borderColor =>
      isDarkMode ? AppColors.darkBorder : AppColors.border;

  /// Cards, sheets, dialogs, tiles.
  Color get surfaceColor =>
      isDarkMode ? AppColors.darkSurface : AppColors.surface;

  /// Tiles nested inside a card.
  Color get surfaceRaised =>
      isDarkMode ? AppColors.darkSurfaceRaised : AppColors.surface;

  /// Scaffold / page canvas.
  Color get bgColor =>
      isDarkMode ? AppColors.darkBackground : AppColors.background;
}
