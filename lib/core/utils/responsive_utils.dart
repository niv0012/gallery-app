import 'package:flutter/material.dart';

/// App-wide breakpoints and helpers so every screen makes layout
/// decisions the same way, instead of each screen inventing its own
/// magic-number width checks.
///
/// Breakpoints are based on *available width* (via [MediaQuery] or a
/// [LayoutBuilder]'s constraints), not device type or platform — this
/// is what makes the same logic correctly handle:
///   - small phones (~360-420dp)
///   - large phones / phones in landscape (~480-600dp)
///   - unfolded foldables (~600-900dp, e.g. Z Fold inner screen ~717dp,
///     Fold7 ~900dp+)
///   - tablets (~600-1024dp portrait, up to ~1280dp landscape)
///   - desktop/web windows, which can be genuinely any width, including
///     ultra-wide monitors
///
/// A folded phone and a small phone both hit [mobile]. An unfolded
/// foldable and a small tablet both hit [tablet]/[foldOrTablet]. This
/// is intentional — the visual outcome (available horizontal space) is
/// what matters, not the device category.
class ResponsiveUtils {
  ResponsiveUtils._();

  /// Below this: phones, folded foldables. Single-column, full-width
  /// controls, bottom nav bars, etc.
  static const double mobileBreakpoint = 600;

  /// Below this: unfolded foldables, small/portrait tablets. Content
  /// can start using two-pane layouts or capped-width centered forms.
  static const double tabletBreakpoint = 900;

  /// Below this: large tablets, small desktop/web windows.
  static const double desktopBreakpoint = 1200;

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < mobileBreakpoint;

  static bool isTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= mobileBreakpoint && w < desktopBreakpoint;
  }

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktopBreakpoint;

  /// True for the "in-between" band that covers unfolded foldables and
  /// small tablets — useful when you want one alternate layout for
  /// "wider than a phone, but not really a desktop" rather than three
  /// separate cases.
  static bool isFoldOrTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= mobileBreakpoint && w < desktopBreakpoint;
  }

  /// Generic three-way picker driven by [MediaQuery] width. Prefer
  /// [responsiveBuilder] inside layouts that are already nested in a
  /// sized ancestor (e.g. inside a side panel), since [MediaQuery] always
  /// reports the *whole window's* width, not the local available width.
  static T value<T>(
    BuildContext context, {
    required T mobile,
    T? tablet,
    T? desktop,
  }) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= desktopBreakpoint) return desktop ?? tablet ?? mobile;
    if (w >= mobileBreakpoint) return tablet ?? mobile;
    return mobile;
  }

  /// Width-aware builder using the *local* constraints (via
  /// [LayoutBuilder]) rather than the whole-window [MediaQuery] size.
  /// Use this for widgets that might live inside a side panel, split
  /// view, or dialog — anywhere the local available width can differ
  /// from the window width.
  static Widget responsiveBuilder({
    required Widget Function(BuildContext context) mobile,
    Widget Function(BuildContext context)? tablet,
    Widget Function(BuildContext context)? desktop,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if (w >= desktopBreakpoint && desktop != null) return desktop(context);
        if (w >= mobileBreakpoint && tablet != null) return tablet(context);
        return mobile(context);
      },
    );
  }

  /// Sensible horizontal content padding that grows with the available
  /// width, so content isn't glued to the edges on wide windows but
  /// isn't wastefully padded on phones either.
  static double horizontalPadding(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= desktopBreakpoint) return 48;
    if (w >= mobileBreakpoint) return 32;
    return 16;
  }

  /// A max content width for text-heavy or form-heavy screens (auth,
  /// settings, profile forms) so lines don't stretch unreadably wide
  /// on tablets/fold/desktop. Mirrors what [AuthContainer] already
  /// does for the auth flow — reuse this constant there too so every
  /// screen agrees on the same cap.
  static const double formMaxWidth = 440;

  /// Wider cap for content grids / galleries, which can reasonably use
  /// more horizontal space than a form before it starts looking sparse.
  static const double contentMaxWidth = 1000;

  /// Column count for a media/photo grid based on available width —
  /// use inside a [LayoutBuilder] (e.g. wrapping a `GridView`) so it
  /// reacts to the pane's actual width, not just the window's.
  static int gridColumns(double maxWidth) {
    if (maxWidth >= 1200) return 6;
    if (maxWidth >= 900) return 5;
    if (maxWidth >= 600) return 4;
    if (maxWidth >= 420) return 3;
    return 2;
  }

  /// Column count for Explorer-style grids (albums / folders) on WIDE
  /// windows. Instead of the phone-tuned fixed 2 / 3-4 / 6 columns —
  /// which turns "Large icons" into a couple of enormous tiles on a
  /// 1400px browser window — pick as many columns as fit the
  /// [targetTileWidth] for the chosen icon size.
  static int columnsForTileWidth(
    double maxWidth,
    double targetTileWidth, {
    int minColumns = 2,
    int maxColumns = 12,
  }) {
    final cols = (maxWidth / targetTileWidth).floor();
    return cols.clamp(minColumns, maxColumns);
  }

  /// Widest a gallery grid is allowed to grow before it's centered with
  /// side margins (keeps ultra-wide monitors from stretching tiles).
  static const double galleryMaxWidth = 1800;

  /// Target tile widths (dp) for Large / Medium / Small icon views.
  static const double tileLarge = 240;
  static const double tileMedium = 160;
  static const double tileSmall = 100;
}
