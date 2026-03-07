import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Breakpoints following Material 3 conventions.
/// - Compact: width < 600 (phones)
/// - Medium: 600 <= width < 840 (small tablets)
/// - Expanded: width >= 840 (tablets, desktops)
enum ScreenSize {
  compact,
  medium,
  expanded,
}

/// Centralized responsive utilities for consistent breakpoint-based layout.
class ResponsiveUtils {
  ResponsiveUtils._();

  static const double _breakpointCompact = 600;
  static const double _breakpointExpanded = 840;

  /// Returns the current screen size based on viewport width.
  static ScreenSize getScreenSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < _breakpointCompact) return ScreenSize.compact;
    if (width < _breakpointExpanded) return ScreenSize.medium;
    return ScreenSize.expanded;
  }

  /// True when viewport width < 600 (phones).
  static bool isCompact(BuildContext context) =>
      getScreenSize(context) == ScreenSize.compact;

  /// True when 600 <= viewport width < 840 (small tablets).
  static bool isMedium(BuildContext context) =>
      getScreenSize(context) == ScreenSize.medium;

  /// True when viewport width >= 840 (tablets, desktops).
  static bool isExpanded(BuildContext context) =>
      getScreenSize(context) == ScreenSize.expanded;

  /// Returns a value based on the current screen size.
  static T responsiveValue<T>(
    BuildContext context, {
    required T compact,
    required T medium,
    required T expanded,
  }) {
    switch (getScreenSize(context)) {
      case ScreenSize.compact:
        return compact;
      case ScreenSize.medium:
        return medium;
      case ScreenSize.expanded:
        return expanded;
    }
  }

  /// Returns padding scaled to screen size (e.g. 12 / 16 / 24).
  static EdgeInsets responsivePadding(BuildContext context) {
    final value = responsiveValue<double>(context, compact: 12, medium: 16, expanded: 24);
    return EdgeInsets.all(value);
  }

  /// Returns horizontal padding scaled to screen size.
  static EdgeInsets responsiveHorizontalPadding(BuildContext context) {
    final value = responsiveValue<double>(context, compact: 12, medium: 16, expanded: 24);
    return EdgeInsets.symmetric(horizontal: value);
  }

  /// Returns symmetric padding scaled to screen size.
  static EdgeInsets responsiveSymmetricPadding(
    BuildContext context, {
    double? horizontal,
    double? vertical,
  }) {
    final h = horizontal ?? responsiveValue<double>(context, compact: 12, medium: 16, expanded: 24);
    final v = vertical ?? responsiveValue<double>(context, compact: 12, medium: 16, expanded: 24);
    return EdgeInsets.symmetric(horizontal: h, vertical: v);
  }

  /// Computes grid crossAxisCount from viewport width.
  /// [minExtent] is the minimum desired cell width (default 140).
  static int responsiveGridColumns(
    BuildContext context, {
    double minExtent = 140,
    int maxColumns = 6,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final count = (width / minExtent).floor();
    return math.min(math.max(count, 1), maxColumns);
  }

  /// Width for dialogs, clamped between min and max.
  static double responsiveDialogWidth(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * 0.9;
    return width.clamp(280.0, 800.0);
  }

  /// Max height for dialogs, clamped relative to screen height.
  static double responsiveDialogHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return (size.height * 0.85).clamp(400.0, 700.0);
  }

  /// Width for side panels (queue, lyrics), clamped between min and max.
  static double responsivePanelWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width * 0.35).clamp(280.0, 420.0);
  }

  /// Responsive icon/thumbnail size for small elements (e.g. list items).
  static double responsiveIconSize(BuildContext context, {double base = 48}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.75,
      medium: base,
      expanded: base,
    );
  }

  /// Responsive icon/thumbnail size for medium elements (e.g. album covers in grids).
  static double responsiveMediumIconSize(BuildContext context, {double base = 80}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.7,
      medium: base * 0.85,
      expanded: base,
    );
  }

  /// Responsive icon/thumbnail size for large elements (e.g. playlist cover).
  static double responsiveLargeIconSize(BuildContext context, {double base = 160}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.6,
      medium: base * 0.8,
      expanded: base,
    );
  }

  /// Responsive card height for grid items.
  static double responsiveCardHeight(BuildContext context, {double base = 112}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.9,
      medium: base,
      expanded: base,
    );
  }

  /// Responsive horizontal list height.
  static double responsiveHorizontalListHeight(BuildContext context, {double base = 230}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.85,
      medium: base * 0.95,
      expanded: base,
    );
  }

  /// Responsive horizontal list card width.
  static double responsiveHorizontalCardWidth(BuildContext context, {double base = 160}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.75,
      medium: base * 0.9,
      expanded: base,
    );
  }

  /// Responsive bottom padding for player bar clearance.
  static double responsivePlayerBottomPadding(BuildContext context, {double base = 120}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.9,
      medium: base,
      expanded: base,
    );
  }

  /// Responsive volume slider width for bottom player.
  static double responsiveVolumeSliderWidth(BuildContext context, {double base = 100}) {
    return responsiveValue<double>(
      context,
      compact: base * 0.8,
      medium: base,
      expanded: base * 1.2,
    );
  }
}
